#if BLOOM_DEVELOPER_STACK_DIAGNOSTICS && BOOM_UI_TEST
#error("Owned public editor diagnostics cannot use the UI test workspace override.")
#endif
import AppKit
import BoomCore
import CryptoKit
import Darwin
import Foundation
import QuartzCore
import SwiftUI

/// One explicit public, warmed, model-free observation of the ordinary editor.
/// Fixed ordinary file recipes; no physical input/IME or
/// compositor acceptance. The guarded stack route requires owned admission;
/// the normal memory route accepts only the two fixed public recipes.
/// Fixture-only hold after the actual production copy wrote its first64KiB.
/// Its signal records entry; the returned production Task owns completion.
private final class DeveloperBackupCopyHold: @unchecked Sendable {
  let signals: AsyncStream<Void>
  private let entered: AsyncStream<Void>.Continuation
  private let documentName: String
  private let releaseSignal = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var observation: (source: URL, staged: URL, bytes: UInt64)?
  private var held = false, expired = false
  init(documentID: UUID) {
    documentName = documentID.uuidString.lowercased()
    let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    signals = stream.stream; entered = stream.continuation
  }
  func copied(_ source: URL, _ staged: URL, _ bytes: UInt64) throws {
    guard source.lastPathComponent == "pages",
      source.deletingLastPathComponent().lastPathComponent == documentName, bytes >= 65_536 else { return }
    lock.lock()
    guard observation == nil else { lock.unlock(); return }
    observation = (source, staged, bytes); held = true
    lock.unlock(); entered.yield(())
    let timedOut = releaseSignal.wait(timeout: .now() + .seconds(10)) != .success
    lock.lock(); held = false; expired = timedOut; lock.unlock()
    if timedOut { throw BoomError.unavailable("Actual public backup copy missed its fixed10s release deadline.") }
  }
  func release() { releaseSignal.signal(); entered.finish() }
  var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }
  var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return expired }
  var actualFiles: (source: URL, staged: URL, bytes: UInt64)? {
    lock.lock(); defer { lock.unlock() }; return observation
  }
}

/// Ordinary AppKit interpretation supplies the Tab oracle; it owns no product
/// source, input context or canonical history.
@MainActor private final class DeveloperInputReferenceView: NSTextView {
  private let referenceUndo = UndoManager()
  override var undoManager: UndoManager? { referenceUndo }
  private(set) var interpretedCommands = 0
  override func doCommand(by selector: Selector) {
    precondition(interpretedCommands < 16)
    interpretedCommands += 1; super.doCommand(by: selector)
  }
}

private struct DeveloperInputControlFailure: Error, LocalizedError {
  let original: Error
  let cleanup: Error
  var errorDescription: String? { "\(original.localizedDescription); actual input-owner join: \(cleanup.localizedDescription)" }
}

@MainActor enum DeveloperEditorFixture {
  private static func placeDiagnosticWindowOnRight(_ window: NSWindow, narrow: Bool = false) {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let visible = screen.visibleFrame
    if narrow {
      let content = window.contentView?.frame.size ?? window.frame.size
      window.setContentSize(NSSize(width: min(content.width, floor(visible.width / 2)),
        height: min(content.height, visible.height - 32)))
    }
    window.setFrameOrigin(NSPoint(x: visible.maxX - window.frame.width,
      y: visible.midY - window.frame.height / 2))
  }

  // Preserve the actual partial Model/window/source on any failed cleanup.
  // This is the existing fixture receiver, not another lifetime or root owner.
  private static var failedFixture: Prepared?
  #if BLOOM_DEVELOPER_STACK_DIAGNOSTICS
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
    } catch {
      failures.append(error.localizedDescription)
      // Preserve the original failure before the capture handshake can fail or
      // its owner terminate this process. This is outside measured input work.
      let description = String(decoding: error.localizedDescription.utf8.prefix(512), as: UTF8.self)
      FileHandle.standardError.write(Data(("Public editor failure before capture finish: " + description + "\n").utf8))
    }
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

  #endif

  /// Same physical public source and ordinary graph as the owned stack fixture.
  /// Normal Release: no transport, suspension, model or cached-view raster in
  /// the timed input loop. Post-loop verification encodes a small clipboard image.
  static func runMemory(arguments: [String]) async throws {
    guard arguments.count == 5, arguments[1] == "--editor-memory-smoke",
      ["short", "gib"].contains(arguments[2]), arguments[3] == "--evidence",
      arguments[4].hasPrefix("/") else { throw BoomError.invalid("Invalid fixed normal editor observation arguments.") }
    let evidence = URL(fileURLWithPath: arguments[4], isDirectory: true)
    guard mkdir(evidence.path, 0o700) == 0 else {
      throw BoomError.invalid("Normal public evidence directory must be fresh and exclusively owned.")
    }
    let plan = try DeveloperStackDiagnostics.PublicEditorPlan(kind: arguments[2] == "short" ? 2 : 3,
      operations: 1_000, utf8Bytes: arguments[2] == "short" ? 72_196 : 1 << 30)
    let fixture = try Prepared(recipe: evidence.appendingPathComponent("normal-editor-recipe.json"),
      plan: plan, normalMemory: true)
    let probe = try ApplicationMemorySmoke.Probe(fixture.memorySamplesURL, observeModelAllocations: false)
    var failures: [String] = []
    do {
      probe.mark("preparation"); try await fixture.prepare()
      probe.mark("steady-native-input-layout"); try await fixture.observe(plan)
      probe.mark("verify-and-close"); try await fixture.verifyAfterCapture()
    } catch { failures.append(error.localizedDescription) }
    do { try await fixture.shutdown() } catch { failures.append("Workspace shutdown: " + error.localizedDescription) }
    if failures.isEmpty {
      probe.mark("released-native-graph")
      await fixture.releaseNormalGraphForObservation()
    }
    do {
      let observed = try probe.finish()
      try fixture.writeNormalMemorySummary(maximumSampledCurrent: probe.maximumSampledCurrentFootprint(),
        kernelLifetimePeak: observed.0, samples: observed.1)
    } catch { failures.append("Memory observation: " + error.localizedDescription) }
    do { try fixture.writeReceipt(captureFinished: false, failures: failures) }
    catch { failures.append("Public fixture receipt: " + error.localizedDescription) }
    if !failures.isEmpty { failedFixture = fixture }
    guard failures.isEmpty else { throw BoomError.unavailable(failures.joined(separator: "; ")) }
  }

  /// Diagnostic control: the same imported document, window and native editor,
  /// with the main run loop alive but no synthetic editing or scroll exercise.
  static func runGraphicsIdle(arguments: [String]) async throws {
    guard arguments.count == 5, arguments[1] == "--graphics-idle-smoke",
      ["empty", "empty-display", "model-empty", "plain-text", "viewport-no-text", "viewport", "clamped-viewport", "clamped-primed", "flattened-primed", "manuscript", "editor", "editor-display", "startup", "primed", "flushed", "exported"].contains(arguments[2]), arguments[3] == "--evidence",
      arguments[4].hasPrefix("/") else { throw BoomError.invalid("Invalid graphics idle diagnostic arguments.") }
    let evidence = URL(fileURLWithPath: arguments[4], isDirectory: true)
    guard mkdir(evidence.path, 0o700) == 0 else {
      throw BoomError.invalid("Graphics idle evidence directory must be fresh and exclusively owned.")
    }
    if arguments[2] == "empty" || arguments[2] == "empty-display" {
      try await runEmptyGraphicsIdle(evidence: evidence, forceDisplay: arguments[2] == "empty-display")
      return
    }
    let plan = try DeveloperStackDiagnostics.PublicEditorPlan(kind: 2, operations: 1_000, utf8Bytes: 72_196)
    let fixture = try Prepared(recipe: evidence.appendingPathComponent("graphics-idle-recipe.json"),
      plan: plan, normalMemory: true, graphicsIdlePoint: arguments[2])
    var failures: [String] = []
    do { try await fixture.prepare() } catch { failures.append("Prepare: " + error.localizedDescription) }
    do { try await fixture.shutdown() } catch { failures.append("Shutdown: " + error.localizedDescription) }
    if failures.isEmpty { await fixture.releaseNormalGraphForObservation() }
    try fixture.writeGraphicsIdleReceipt(failures: failures)
    if !failures.isEmpty { failedFixture = fixture }
    guard failures.isEmpty else { throw BoomError.unavailable(failures.joined(separator: "; ")) }
  }

  private static func runEmptyGraphicsIdle(evidence: URL, forceDisplay: Bool) async throws {
    var stages: [[String: Any]] = []
    var host: NSHostingView<EmptyView>? = NSHostingView(rootView: EmptyView())
    var window: NSWindow? = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 846))
    func mark(_ name: String) {
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
      let capacity = Int(count)
      let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }
      stages.append(["stage": name, "uptime_seconds": ProcessInfo.processInfo.systemUptime,
        "available": status == KERN_SUCCESS && Int(count) == capacity,
        "graphics_footprint_bytes": info.ledger_tag_graphics_footprint,
        "physical_footprint_bytes": info.phys_footprint,
        "window_visible": window?.isVisible ?? false,
        "window_key": window?.isKeyWindow ?? false,
        "window_occlusion_visible": window?.occlusionState.contains(.visible) ?? false,
        "window_backing_scale": window?.backingScaleFactor ?? 0])
    }
    guard host != nil, window != nil else { throw BoomError.unavailable("Empty graphics control could not construct its window.") }
    window?.isReleasedWhenClosed = false; window?.contentView = host
    mark("attached-hidden")
    if let window { placeDiagnosticWindowOnRight(window, narrow: true) }
    window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    for _ in 0..<10 { host?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
    mark("visible-empty")
    if forceDisplay { window?.displayIfNeeded(); CATransaction.flush(); mark("display-submitted") }
    for tick in 1...20 { try await Task.sleep(for: .milliseconds(100)); mark("idle-empty-\(tick)") }
    weak var oldWindow = window
    weak var oldHost = host
    window?.contentView = nil; window?.close()
    host = nil; window = nil
    try await Task.sleep(for: .seconds(1))
    mark("released-empty")
    let released: [String: Any] = ["window_deallocated": oldWindow == nil,
      "host_deallocated": oldHost == nil]
    let receipt: [String: Any] = ["schema": 1, "scope": "Diagnostic empty SwiftUI host in the production window factory",
      "status": "complete", "force_display": forceDisplay,
      "graphics_lifecycle_stages": stages, "released_graph_owners": released]
    try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
      .write(to: evidence.appendingPathComponent("graphics-idle-receipt.json"), options: .withoutOverwriting)
  }

  @MainActor private final class Prepared {
    private static let cycles: UInt32 = 1_000
    private static let observationSeconds: Int64 = 110
    private static let normalObservationSeconds: Int64 = 140
    private let normalMemory: Bool
    private let graphicsIdlePoint: String?
    private let plan: DeveloperStackDiagnostics.PublicEditorPlan
    private let root: URL
    private let temporaryRoot: URL
    private let providedTemporaryPath: String?
    private var workspace: WorkspaceModel?
    private var host: NSView?
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
    private var startupUndoGroups = 0
    private var startupImportedState: [String: Any]?, startupHistoryState: [String: Any]?
    private var primingBefore: [String: Any]?, primingAfterInsert: [String: Any]?, primingAfterDelete: [String: Any]?
    private var vmBefore: [String: Any]?, vmAfter: [String: Any]?
    private var graphicsStages: [[String: Any]] = []
    private var graphicsLayerHierarchy: [[String: Any]] = []
    private let graphicsRunID = UUID()
    private var releasedGraphOwners: [String: Bool] = [:]
    private var applicationBeforeFocus: [String: Any]?, applicationAfterFocus: [String: Any]?
    private var reactivationCount = 0, lastReactivationEvent: UInt64 = 0
    private var reactivationTotalSeconds: Double = 0, reactivationMaximumSeconds: Double = 0
    private var normalTimings: [[String: Any]] = []
    private var liveBackupVerified = false, cancelledBackupVerified = false, backupColdRestoreVerified = false
    private var backupControlStage = "unentered", backupPhaseActive = false, backupOriginalClosed = false
    private var backupCapturedRecord: PagedDocumentRootRecord?
    private var backupCapturedSelection: PagedNativeNavigationSelection?
    private var backupCapturedDigest: String?, backupAttachmentID: UUID?
    private var backupOriginalIncarnation: UUID?, backupOriginalSessionID: UUID?
    private var backupRestored: WorkspaceModel?
    private var backupRestoredHost: NSHostingView<WorkspaceView>?
    private var backupRestoredWindow: NSWindow?
    private var backupRestoreCloseAttempted = false
    private var heldWriterVerified = false
    private var heldScrollShiftVerified = false, visibleDemandVerified = false, collapsedMediaVerified = false
    private var markupVerificationStage = "unentered"
    private var heldWriterFailureState: [String: Any]?
    private var documentInputStage = "unentered"
    private var documentContextVerified = false, adoptingFinalVerified = false, tabPointerVerified = false
    private var firstKeyFocusVerified = false
    private var adoptingFinalQueuedAtFocus: Int?
    private var nativeTabObservations: [[String: Any]] = []
    private var warmMarkedStates: [[String: Any]] = []
    private var heldSave: Task<Void, Error>?
    var memorySamplesURL: URL { root.appendingPathComponent("memory-samples.jsonl") }

    init(recipe: URL, plan: DeveloperStackDiagnostics.PublicEditorPlan, normalMemory: Bool = false,
      graphicsIdlePoint: String? = nil) throws {
      guard plan.operations == (plan.isMixed ? 200 : Self.cycles) else {
        throw BoomError.invalid("Public editor plan differs from its fixed source recipe.")
      }
      self.plan = plan; self.normalMemory = normalMemory; self.graphicsIdlePoint = graphicsIdlePoint
      root = recipe.deletingLastPathComponent().appendingPathComponent("public-editor-workspace", isDirectory: true)
      if normalMemory {
        guard let path = ProcessInfo.processInfo.environment["TMPDIR"], !path.isEmpty, path.hasPrefix("/") else {
          throw BoomError.invalid("Normal public fixture requires its actual absolute caller TMPDIR.")
        }
        let supplied = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        providedTemporaryPath = supplied.path
        temporaryRoot = supplied.resolvingSymlinksInPath().standardizedFileURL
      } else {
        providedTemporaryPath = nil
        temporaryRoot = recipe.deletingLastPathComponent().appendingPathComponent("public-editor-tmp", isDirectory: true)
      }
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
      let suppliedPath = ProcessInfo.processInfo.environment["TMPDIR"]
      let pathMatches: Bool
      if normalMemory, let suppliedPath, let providedTemporaryPath {
        let supplied = URL(fileURLWithPath: suppliedPath, isDirectory: true).standardizedFileURL
        pathMatches = supplied.path == providedTemporaryPath
          && supplied.resolvingSymlinksInPath().standardizedFileURL == temporaryRoot
      } else {
        pathMatches = suppliedPath == temporaryRoot.path && temporaryRoot.resolvingSymlinksInPath() == temporaryRoot
      }
      guard pathMatches else {
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
      if normalMemory { recordGraphicsStage("before-window") }
      if graphicsIdlePoint == "clamped-viewport" || graphicsIdlePoint == "clamped-primed" {
        guard let viewport = model.pagedViewport,
          let native = viewport.textView as? PagedNativeTextView else {
          throw BoomError.invalid("Geometry control has no native editor.")
        }
        let height: CGFloat = 846 // matched diagnostic window content height
        native.isVerticallyResizable = false
        native.maxSize = NSSize(width: native.maxSize.width, height: height)
        native.textContainer?.heightTracksTextView = true
        native.setFrameSize(NSSize(width: native.frame.width, height: height))
        recordGraphicsStage("clamped-before-host")
      }
      if graphicsIdlePoint == "viewport-no-text" {
        guard let viewport = model.pagedViewport else {
          throw BoomError.invalid("Detached-text graphics control has no viewport.")
        }
        viewport.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1190, height: 846))
        recordGraphicsStage("text-detached-before-host")
      }
      // Capture the exact fresh imported value BEFORE exposing a key window.
      // A file revision/summary alone cannot identify a same-length native edit.
      let startupSession = model.pagedSession, startupCommands = model.pagedCommands
      var startupImported: PagedNativeLogicalSnapshot?
      if plan.isMixed || normalMemory {
        guard let startupSession, let startupCommands else {
          throw BoomError.invalid("The fresh public import lost its actual native history owner.")
        }
        let imported = try startupCommands.captureLogicalHistory()
        guard startupSession.generation == 0, imported.generation == 0,
          startupSession.sealedRootRecord.historyGeneration == 0,
          imported.undo.isEmpty, imported.redo.isEmpty, imported.activeGroup == nil,
          imported.snapshot.sourceRevision == importedRevision,
          imported.snapshot.summary == importedRevision.summary,
          imported.snapshot.sessionID == startupSession.sessionID,
          imported.snapshot.sourceRevision.documentID == id else {
          throw BoomError.invalid("The public import did not begin with its exact fresh source and empty native history.")
        }
        startupImported = imported.snapshot
        startupImportedState = ["root": imported.snapshot.rootID.uuidString,
          "document": id.uuidString, "session": startupSession.sessionID.uuidString,
          "engine": startupSession.engineIncarnation.uuidString, "generation": imported.generation,
          "persisted_history_generation": startupSession.sealedRootRecord.historyGeneration,
          "undo_count": imported.undo.count, "redo_count": imported.redo.count]
      }
      let host: NSView
      switch graphicsIdlePoint {
      case "model-empty": host = NSHostingView(rootView: EmptyView())
      case "plain-text":
        guard let original = model.pagedViewport?.textView else {
          throw BoomError.invalid("Plain text graphics control has no source window.")
        }
        let storage = NSTextStorage(string: original.string), manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1190, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 1190, height: 846), textContainer: container)
        text.isEditable = true; text.isRichText = false; text.drawsBackground = false
        text.font = original.font; text.textContainerInset = original.textContainerInset
        text.isHorizontallyResizable = false; text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        container.widthTracksTextView = true; container.heightTracksTextView = false
        text.sizeToFit()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1190, height: 846))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.documentView = text
        host = scroll
      case "viewport", "viewport-no-text", "clamped-viewport":
        guard let viewport = model.pagedViewport else { throw BoomError.invalid("Viewport graphics control has no native viewport.") }
        host = NSHostingView(rootView: PagedManuscriptView(viewport: viewport))
      case "manuscript": host = NSHostingView(rootView: ManuscriptPane(model: model))
      default: host = NSHostingView(rootView: WorkspaceView(model: model))
      }
      self.host = host
      let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 846))
      self.window = window; window.isReleasedWhenClosed = false; window.contentView = host
      if normalMemory { recordGraphicsStage("attached-hidden") }
      if plan.isMixed || normalMemory {
        DeveloperEditorFixture.placeDiagnosticWindowOnRight(window, narrow: graphicsIdlePoint != nil)
        if NSApp.activationPolicy() != .regular {
          _ = NSApp.setActivationPolicy(.regular)
        }
        guard NSApp.activationPolicy() == .regular else {
          throw BoomError.unavailable("Mixed diagnostics cannot acquire their actual native action route.")
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
      }
      for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
      if graphicsIdlePoint == "flattened-primed" {
        guard let clip = model.pagedViewport?.contentView, clip.layer != nil else {
          throw BoomError.invalid("Layer control has no attached clip backing layer after layout.")
        }
        clip.canDrawSubviewsIntoLayer = true
      }
      // Initial external foreground delivery is preparation, outside measured
      // work. Later restoration/reactivation keeps its existing five-second bound.
      if plan.isMixed || normalMemory { try await receiveActualKeyWindow(window, within: .seconds(15)) }
      if graphicsIdlePoint == "model-empty" {
        recordGraphicsStage("visible-model-empty")
        _ = try await observeGraphicsIdle(at: "model-empty")
        return
      }
      if graphicsIdlePoint == "plain-text" {
        if let plain = (host as? NSScrollView)?.documentView as? NSTextView {
          _ = window.makeFirstResponder(plain)
        }
        recordGraphicsStage("visible-plain-text")
        _ = try await observeGraphicsIdle(at: "plain-text")
        return
      }
      if graphicsIdlePoint == "viewport-no-text" {
        recordGraphicsStage("visible-viewport-no-text")
        _ = try await observeGraphicsIdle(at: "viewport-no-text")
        return
      }
      guard let view = model.pagedViewport?.textView as? PagedNativeTextView,
        model.pagedInput?.activeView === view, window.makeFirstResponder(view), view.isEditable else {
        throw BoomError.invalid("Ordinary managed public editor focus was unavailable.")
      }
      managedEditor = view
      if normalMemory { recordGraphicsStage("visible-editor") }
      if try await observeGraphicsIdle(at: "editor") { return }
      if try await observeGraphicsIdle(at: "editor-display") { return }
      if try await observeGraphicsIdle(at: "viewport") { return }
      if try await observeGraphicsIdle(at: "clamped-viewport") { return }
      if try await observeGraphicsIdle(at: "manuscript") { return }
      var primingView = view
      if plan.isMixed || normalMemory {
        startupBefore = try nativePreparationState(view)
        try await joinMixedInput(0, measured: false)
        let current = try currentMixedView()
        guard let startupSession, let startupCommands, let startupImported,
          current.session === startupSession, model.pagedCommands === startupCommands,
          model.selectedDocumentID == id else {
          throw BoomError.invalid("Public startup input lost its original document/session/history owner.")
        }
        let history = try startupCommands.captureLogicalHistory()
        try history.validate() // the existing combined100-entry native bound
        startupHistoryState = ["root": history.snapshot.rootID.uuidString,
          "imported_root": startupImported.rootID.uuidString,
          "generation": current.session.generation, "capture_generation": history.generation,
          "sealed_source_generation": current.session.sealedGeneration,
          "persisted_history_generation": current.session.sealedRootRecord.historyGeneration,
          "undo_count": history.undo.count, "redo_count": history.redo.count,
          "oldest_undo_root": history.undo.first?.snapshot.rootID.uuidString ?? "nil"]
        guard history.generation == current.session.generation else {
          throw BoomError.invalid("The actual startup capture lost its live source generation.")
        }
        if !history.snapshot.isSame(startupImported) {
          // Incidental public input can span several real groups. Only the
          // exact pre-exposure imported root may be the oldest retained target.
          guard history.undo.first?.snapshot.isSame(startupImported) == true else {
            throw BoomError.invalid("Public startup Undo does not reach the exact fresh imported source.")
          }
          startupUndoAttempted = true
          for entry in history.undo.reversed() {
            let pending = try startupCommands.captureLogicalHistory()
            guard let next = pending.undo.last, next.groupID == entry.groupID,
              next.cursor == entry.cursor, next.snapshot.isSame(entry.snapshot) else {
              throw BoomError.invalid("Actual startup history changed before its next responder Undo.")
            }
            try await mixedResponder(false, event: 0, measured: false)
            startupUndoGroups += 1
            primingView = try currentMixedView()
            guard primingView.session === startupSession,
              try primingView.session.captureLogicalState().source.isSame(entry.snapshot) else {
              throw BoomError.invalid("An actual startup Undo did not reach its captured native target.")
            }
          }
        }
        primingView = try currentMixedView()
        guard try primingView.session.captureLogicalState().source.isSame(startupImported),
          primingView.session.sealedGeneration == primingView.session.generation,
          model.pagedSelectedRecord?.document.revision.summary == importedRevision.summary,
          try primingView.session.documentCoordinates().projectedUTF16 == extent else {
          throw BoomError.invalid("Startup recovery did not restore the exact original public source.")
        }
        startupUndoJoined = startupUndoAttempted
        startupAfter = try nativePreparationState(primingView)
      }
      if normalMemory { recordGraphicsStage("startup-input-recovered") }
      if try await observeGraphicsIdle(at: "startup") { return }
      primingView.setSelectedRange(NSRange(location: 0, length: 0))
      if plan.isMixed { primingBefore = try nativePreparationState(primingView) }
      primingView.insertText("x", replacementRange: primingView.selectedRange())
      if plan.isMixed { primingAfterInsert = try nativePreparationState(primingView) }
      primingView.insertText("", replacementRange: NSRange(location: 0, length: 1))
      if plan.isMixed { primingAfterDelete = try nativePreparationState(primingView) }
      host.layoutSubtreeIfNeeded()
      if normalMemory { recordGraphicsStage("primed-native-layout") }
      if try await observeGraphicsIdle(at: "primed") { return }
      if try await observeGraphicsIdle(at: "flattened-primed") { return }
      if try await observeGraphicsIdle(at: "clamped-primed") { return }
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
      if !normalMemory {
        if !plan.isMixed { try prepareBitmap(for: preparedView, window: window) }
        try rasterize(preparedView, target: plan.isMixed ? model.pagedViewport : nil)
      }
      try await model.flush() // actual canonical/worker join, not a delay or flag
      if normalMemory { recordGraphicsStage("flushed") }
      if try await observeGraphicsIdle(at: "flushed") { return }
      try requireManagedSource()
      try await verifyOrdinaryExport(named: "prepared-export.txt"); preparationExportJoined = true
      if normalMemory { recordGraphicsStage("export-verified") }
      if try await observeGraphicsIdle(at: "exported") { return }
      if plan.isMixed || normalMemory { try await verifyHeldWriterEditing() }
      if normalMemory { recordGraphicsStage("held-writer-verified") }
      if plan.utf8Bytes == 72_196 && (plan.isMixed || normalMemory) { try await verifyLiveBackupControls() }
      if normalMemory { recordGraphicsStage("backup-verified") }
      if plan.utf8Bytes == 72_196 && (plan.isMixed || normalMemory) { try await verifyDocumentInputControls() }
      if normalMemory { recordGraphicsStage("input-controls-verified") }
      _ = try diskExtent(reservingReceipt: true)
      vmBefore = currentVMCategories()
    }

    // These functional controls use the already-open public short document and
    // actual App.run/key window, before any measured/donated operation. They
    // exercise protocol callbacks and synthesized native events, not hardware
    // keyboard or an external input-method service.
    private func verifyDocumentInputControls() async throws {
      guard plan.utf8Bytes == 72_196, NSApp.isRunning, NSApp.isActive,
        let model = workspace, let session = model.pagedSession else {
        throw BoomError.invalid("Document input controls require the actual public short App route.")
      }
      _ = try currentMixedView()
      let original = try session.captureLogicalState().source
      let bytes = try await documentInputBytes()
      guard UInt64(bytes.count) == plan.utf8Bytes else {
        throw BoomError.invalid("Document input controls lost their exact short baseline.")
      }
      documentInputStage = "document-context"
      try await verifyDocumentContext(original: original, bytes: bytes)
      documentContextVerified = true
      documentInputStage = "adopting-final"
      try await verifyAdoptingFinal(original: original, bytes: bytes)
      adoptingFinalVerified = true
      documentInputStage = "tab-pointer"
      try await verifyTabPointer(original: original, bytes: bytes)
      tabPointerVerified = true
      documentInputStage = "first-key-focus"
      try await verifyFirstKeyFocus(original: original, bytes: bytes)
      firstKeyFocusVerified = true
      try await mixedCaret(0, event: 0, measured: false)
      try await model.flush()
      try await requireDocumentInputSource(bytes, root: original)
      _ = try currentMixedView()
      documentInputStage = "complete"
    }

    private func documentInputBytes() async throws -> Data {
      guard let model = workspace, let session = model.pagedSession, let engine = model.pagedEngine else {
        throw BoomError.stale("The public context reader lost its actual source.")
      }
      let read = try session.captureLogicalRead()
      guard read.source.summary.bytes <= UInt64(PagedTextWindow.maximumBytes) else {
        throw BoomError.budget("Complete context-control readback is limited to the public short source.")
      }
      let bytes = try await engine.logicalBytes(read.source, byteRange: 0..<read.source.summary.bytes)
      try session.admitLogicalRead(read)
      guard UInt64(bytes.count) == read.source.summary.bytes else {
        throw BoomError.invalid("The context control did not read the whole captured short source.")
      }
      return bytes
    }
    private func requireDocumentInputSource(_ expected: Data, root: PagedNativeLogicalSnapshot? = nil) async throws {
      let bytes = try await documentInputBytes()
      guard bytes == expected, let session = workspace?.pagedSession else {
        throw BoomError.invalid("Actual context input/SDK Undo changed the exact public source or root.")
      }
      if let root {
        let current = try session.captureLogicalState()
        guard current.source.isSame(root) else {
          throw BoomError.invalid("Actual responder Undo did not restore its original logical root.")
        }
      }
    }
    private func joinedDocumentInputFailure(_ original: Error) async -> Error {
      var failure = original
      // Temporary reference controls/mount hooks remain alive until every
      // entered owner task has joined. A failed close still retains Prepared.
      if let commands = workspace?.pagedCommands {
        do { try await commands.joinPendingCommand() }
        catch { failure = DeveloperInputControlFailure(original: failure, cleanup: error) }
      }
      if let viewport = workspace?.pagedViewport {
        do { try await viewport.joinPresentation() }
        catch { failure = DeveloperInputControlFailure(original: failure, cleanup: error) }
      }
      return failure
    }

    private func verifyDocumentContext(original: PagedNativeLogicalSnapshot, bytes: Data) async throws {
      guard let model = workspace, let input = model.pagedInput, let commands = model.pagedCommands,
        let session = model.pagedSession else { throw BoomError.stale("Document context control lost its actual owner.") }
      do {
        try await mixedCaret(0, event: 0, measured: false)
        let view = try currentMixedView()
        guard let context = view.inputContext, let client = context.client as? PagedNativeTextInputClient,
          let binding = view.inputBinding else { throw BoomError.invalid("The actual document context is absent.") }
        let storage = view.boundedStorage, oldText = storage.string, arena = session.arenaID
        let generation = session.generation
        let projected = try await commands.navigate(toUTF16: 48_000,
          selectingUTF16: PagedNativeNavigationSelection(utf16Offset: 50_000, utf16Length: 0))
        try await commands.joinPendingCommand()
        guard try currentMixedView() === view, view.inputContext === context, !client.isRetired,
          session.arenaID != arena, binding.state == .retired, session.generation == generation,
          client.selectedRange() == NSRange(location: 50_000, length: 0) else {
          throw BoomError.invalid("Far navigation did not retain the live document context across its actual arena mount.")
        }
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "OLD")
        guard storage.string == oldText, session.generation == generation, projected.start.utf16 >= 10 else {
          throw BoomError.invalid("Retired storage changed the current document or the far read was not genuine.")
        }
        var actual = NSRange(location: NSNotFound, length: 0)
        let requested = NSRange(location: Int(projected.start.utf16) - 10, length: 30)
        guard let bounded = client.attributedSubstring(forProposedRange: requested, actualRange: &actual),
          actual == NSRange(location: Int(projected.start.utf16), length: 20),
          bounded.string == String(projected.text.prefix(20)),
          client.attributedSubstring(forProposedRange: NSRange(location: 0, length: 1), actualRange: &actual) == nil,
          actual == NSRange(location: NSNotFound, length: 0) else {
          throw BoomError.invalid("The document context did not expose its exact bounded global substring.")
        }
        let published = session.sealedRootRecord, sealedGeneration = session.sealedGeneration
        client.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
          replacementRange: NSRange(location: 50_000, length: 0))
        guard view.hasMarkedText(), session.isPinned,
          client.markedRange() == NSRange(location: 50_000, length: 1),
          session.sealedRootRecord == published, session.sealedGeneration == sealedGeneration else {
          throw BoomError.invalid("The real marked document context lost its global range/pin or published prematurely.")
        }
        client.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await commands.joinPendingCommand()
        let expected = (String(decoding: bytes, as: UTF8.self) as NSString)
          .replacingCharacters(in: NSRange(location: 50_000, length: 0), with: "日本")
        guard !view.hasMarkedText(), !session.isPinned, view.inputContext === context,
          client.selectedRange() == NSRange(location: 50_002, length: 0) else {
          throw BoomError.invalid("Final native text did not replace its actual marked global range.")
        }
        try await requireDocumentInputSource(Data(expected.utf8))
        try await mixedResponder(false, event: 0, measured: false)
        try await requireDocumentInputSource(bytes, root: original)
        try await mixedResponder(true, event: 0, measured: false)
        try await requireDocumentInputSource(Data(expected.utf8))
        try await mixedResponder(false, event: 0, measured: false)
        try await requireDocumentInputSource(bytes, root: original)
        guard input.firstRefusal == nil, commands.firstFailure == nil, view.inputContext === context,
          !client.isRetired else { throw BoomError.invalid("Actual context/SDK history did not remain live.") }
      } catch { let failure = await joinedDocumentInputFailure(error); throw failure }
    }

    private func verifyAdoptingFinal(original: PagedNativeLogicalSnapshot, bytes: Data) async throws {
      guard let model = workspace, let input = model.pagedInput, let commands = model.pagedCommands,
        let session = model.pagedSession, let window, let mount = commands.mountView else {
        throw BoomError.stale("Adopting final control lost its actual graph/mount.")
      }
      let view = try currentMixedView()
      guard let context = view.inputContext, let client = context.client as? PagedNativeTextInputClient else {
        throw BoomError.invalid("Adopting final control has no live document context.")
      }
      let other = NSTextField(frame: NSRect(x: 800, y: 0, width: 200, height: 24))
      window.contentView!.addSubview(other)
      defer { other.removeFromSuperview(); commands.mountView = mount }
      var entered = false
      var acceptedResponder: NSResponder?
      let final = NSMutableAttributedString(string: "X", attributes: [.markedClauseSegment: NSNumber(value: 3)])
      let retained = commands.retainedInputBytes, generation = session.generation
      do {
        try await mixedCaret(0, event: 0, measured: false)
        view.setSelectedRange(NSRange(location: 8, length: 0))
        client.withNativeEvent { _ = client.selectedRange() }
        commands.mountView = { old, new in
          try mount(old, new)
          guard !entered else { return }; entered = true
          guard input.isAdopting, new.inputContext === context else {
            throw BoomError.invalid("Final callback was not held by an actual arena adoption.")
          }
          client.insertText(final, replacementRange: NSRange(location: NSNotFound, length: 0))
          client.insertText("Y", replacementRange: NSRange(location: NSNotFound, length: 0))
          guard commands.queuedNativeContinuationCount == 2, commands.retainedRefusedInputCount == 0,
            commands.retainedInputBytes > retained, session.generation == generation else {
            throw BoomError.invalid("Adopting final callbacks were lost, applied early or retained as refusals.")
          }
          final.replaceCharacters(in: NSRange(location: 0, length: 1), with: "WRONG")
        }
        _ = try await commands.navigate(toUTF16: 48_000,
          selectingUTF16: PagedNativeNavigationSelection(utf16Offset: 50_000, utf16Length: 0))
        guard entered else { throw BoomError.invalid("Final callback control never entered the actual adoption.") }
        // Adoption first completes its captured-focus restoration. Record the
        // actual queue at this later focus move rather than claiming a race.
        adoptingFinalQueuedAtFocus = commands.queuedNativeContinuationCount
        guard window.makeFirstResponder(other), window.firstResponder !== view else {
          throw BoomError.invalid("The actual later focus move was not admitted.")
        }
        acceptedResponder = window.firstResponder
        try await commands.joinPendingCommand()
        guard entered, acceptedResponder != nil, window.firstResponder === acceptedResponder,
          window.firstResponder !== view,
          commands.queuedNativeContinuationCount == 0, commands.retainedRefusedInputCount == 0,
          commands.retainedInputBytes == retained, session.generation == generation + 2 else {
          throw BoomError.invalid("Accepted final text did not join exactly once without stealing actual focus.")
        }
        let originalText = String(decoding: bytes, as: UTF8.self)
        let expected = (originalText as NSString).replacingCharacters(in: NSRange(location: 8, length: 0), with: "XY")
        try await requireDocumentInputSource(Data(expected.utf8))
        guard window.makeFirstResponder(view), window.firstResponder === view else {
          throw BoomError.unavailable("The actual editor could not resume its responder Undo control.")
        }
        commands.mountView = mount
        try await mixedResponder(false, event: 0, measured: false)
        let beforeY = (originalText as NSString).replacingCharacters(in: NSRange(location: 8, length: 0), with: "X")
        try await requireDocumentInputSource(Data(beforeY.utf8))
        try await mixedResponder(false, event: 0, measured: false)
        try await requireDocumentInputSource(bytes, root: original)
        guard view.inputContext === context, !client.isRetired, input.firstRefusal == nil,
          commands.firstFailure == nil else { throw BoomError.invalid("Adopting final delivery poisoned later input/Undo.") }
      } catch { let failure = await joinedDocumentInputFailure(error); throw failure }
    }

    private func verifyTabPointer(original: PagedNativeLogicalSnapshot, bytes: Data) async throws {
      guard let model = workspace, let input = model.pagedInput, let session = model.pagedSession,
        let commands = model.pagedCommands, let viewport = model.pagedViewport, let window else {
        throw BoomError.stale("Tab pointer control lost its actual graph.")
      }
      for shifting in [false, true] {
        documentInputStage = shifting ? "backtab-pointer" : "tab-pointer"
        let view = try currentMixedView(), previousNext = view.nextKeyView
        let reference = DeveloperInputReferenceView(frame: NSRect(x: 800, y: 40, width: 280, height: 48))
        reference.isRichText = false; reference.string = "ab"
        let before = NSTextField(frame: NSRect(x: 800, y: 0, width: 100, height: 24))
        let after = NSTextField(frame: NSRect(x: 920, y: 0, width: 100, height: 24))
        window.contentView!.addSubview(reference); window.contentView!.addSubview(before); window.contentView!.addSubview(after)
        defer {
          view.nextKeyView = previousNext
          reference.removeFromSuperview(); before.removeFromSuperview(); after.removeFromSuperview()
        }
        before.nextKeyView = reference; reference.nextKeyView = after
        after.nextKeyView = view; view.nextKeyView = before
        @MainActor func key(_ tab: Bool) throws -> NSEvent {
          let characters = tab ? (shifting ? "\u{19}" : "\t") : "Y"
          guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: tab && shifting ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: tab ? "\t" : "Y", isARepeat: false, keyCode: tab ? 48 : 16) else {
            throw BoomError.invalid("The public native key event is unavailable.")
          }
          return event
        }
        do {
          try await mixedCaret(0, event: 0, measured: false)
          reference.setSelectedRange(NSRange(location: 1, length: 0))
          guard window.makeFirstResponder(reference), window.firstResponder === reference else {
            throw BoomError.unavailable("The actual ordinary Tab reference could not receive focus.")
          }
          window.sendEvent(try key(true))
          let ordinary = reference.string, ordinaryFocus = window.firstResponder === reference
          guard reference.interpretedCommands > 0, ordinary.hasPrefix("a"), ordinary.hasSuffix("b"),
            ordinary.utf16.count <= 34 else {
            throw BoomError.invalid("The ordinary native Tab/Backtab reference produced no supported actual interpretation.")
          }
          let inserted = String(ordinary.dropFirst().dropLast())
          guard window.makeFirstResponder(view), window.firstResponder === view else {
            throw BoomError.unavailable("The actual document could not receive the queued Tab control.")
          }
          try viewport.requestScroll(toUTF16: 40_000); try await viewport.joinPresentation()
          guard let projection = viewport.visibleScrollWindow,
            let surface = viewport.subviews.compactMap({ $0 as? NSScrollView }).first(where: { !$0.isHidden }),
            let display = surface.documentView as? NSTextView else {
            throw BoomError.invalid("The actual readonly pointer target was not installed.")
          }
          let visible = display.visibleRect.intersection(display.bounds)
          let point = NSPoint(x: display.textContainerOrigin.x + 22,
            y: visible.minY + min(24, visible.height / 2))
          guard visible.contains(point), display.window === window,
            let content = window.contentView, let parent = content.superview,
            content.hitTest(parent.convert(point, from: display)) === display else {
            throw BoomError.invalid("The public pointer target is outside its actual visible text surface.")
          }
          let caret = try projection.position(localUTF16: display.characterIndexForInsertion(at: point)).utf16
          let navigationCaret: UInt64 = 12_001, generation = session.generation
          guard caret > navigationCaret else { throw BoomError.invalid("Pointer chronology requires the real distant target.") }
          let location = display.convert(point, to: nil)
          @MainActor func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
              context: nil, eventNumber: type == .leftMouseDown ? 1 : 2, clickCount: 1,
              pressure: type == .leftMouseUp ? 0 : 1) else { throw BoomError.invalid("The public pointer event is unavailable.") }
            return event
          }
          // No await occurs between request and the four original events.
          // The existing MainActor owner has the real navigation Task before
          // its worker can return; no synthetic window/ACK or storage gate.
          try commands.requestDocumentNavigation(toUTF16: 12_000,
            selectingUTF16: PagedNativeNavigationSelection(utf16Offset: navigationCaret, utf16Length: 0),
            expected: try session.documentCoordinates())
          window.sendEvent(try key(true))
          guard commands.queuedRawKeyCount == 1, commands.canOrderPointerAfterNavigation else {
            throw BoomError.invalid("Actual Tab/Backtab was not held ahead of the real pointer intent.")
          }
          window.sendEvent(try mouse(.leftMouseDown)); window.sendEvent(try mouse(.leftMouseUp))
          window.sendEvent(try key(false))
          guard commands.queuedRawKeyCount == 2, commands.retainedRefusedInputCount == 0 else {
            throw BoomError.invalid("Tab, pointer and later typing did not retain their actual chronological input.")
          }
          try await commands.joinPendingCommand(); try await viewport.joinPresentation()
          let mappedCaret = caret + UInt64(inserted.utf16.count)
          let expected = NSMutableString(string: String(decoding: bytes, as: UTF8.self))
          expected.insert(inserted, at: Int(navigationCaret)); expected.insert("Y", at: Int(mappedCaret))
          try await requireDocumentInputSource(Data((expected as String).utf8))
          guard try input.currentDocumentSelection().utf16Offset == mappedCaret + 1,
            session.generation == generation + (inserted.isEmpty ? 1 : 2), window.firstResponder === view,
            commands.queuedRawKeyCount == 0, commands.retainedInputBytes == 0,
            commands.retainedRefusedInputCount == 0, viewport.presentationFailure == nil else {
            throw BoomError.invalid("Actual Tab/pointer replay lost its mapped source, caret or physical focus.")
          }
          try await mixedResponder(false, event: 0, measured: false)
          let beforeY = NSMutableString(string: String(decoding: bytes, as: UTF8.self))
          beforeY.insert(inserted, at: Int(navigationCaret))
          try await requireDocumentInputSource(Data((beforeY as String).utf8))
          guard try input.currentDocumentSelection().utf16Offset == mappedCaret else {
            throw BoomError.invalid("Responder Undo did not restore the actual pointer caret.")
          }
          try await mixedResponder(true, event: 0, measured: false)
          try await requireDocumentInputSource(Data((expected as String).utf8))
          try await mixedResponder(false, event: 0, measured: false)
          if !inserted.isEmpty { try await mixedResponder(false, event: 0, measured: false) }
          try await requireDocumentInputSource(bytes, root: original)
          guard input.firstRefusal == nil, commands.firstFailure == nil, nativeTabObservations.count < 2 else {
            throw BoomError.invalid("Actual Tab/pointer history left a refusal or exceeded its two native oracles.")
          }
          nativeTabObservations.append(["backtab": shifting, "reference_inserted_utf16": inserted.utf16.count,
            "reference_kept_focus": ordinaryFocus, "captured_pointer_utf16": caret, "mapped_pointer_utf16": mappedCaret])
        } catch { let failure = await joinedDocumentInputFailure(error); throw failure }
      }
    }

    private func verifyFirstKeyFocus(original: PagedNativeLogicalSnapshot, bytes: Data) async throws {
      guard let model = workspace, let input = model.pagedInput, let session = model.pagedSession,
        let commands = model.pagedCommands, let viewport = model.pagedViewport, let window else {
        throw BoomError.stale("First-key focus control lost its actual document graph.")
      }
      try await mixedCaret(0, event: 0, measured: false)
      let view = try currentMixedView()
      guard let context = view.inputContext, let client = context.client as? PagedNativeTextInputClient else {
        throw BoomError.invalid("The first-key focus control has no actual document context.")
      }
      let other = NSTextView(frame: NSRect(x: 800, y: 80, width: 240, height: 48))
      other.string = "Other"; window.contentView!.addSubview(other)
      defer { other.removeFromSuperview() }
      do {
        let selected = PagedNativeNavigationSelection(utf16Offset: 1_024, utf16Length: 48_976,
          focusAtEnd: false, affinity: .upstream)
        try input.setDocumentSelection(selected)
        let before = try session.captureLogicalState(), history = try commands.captureLogicalHistory()
        let retained = commands.retainedInputBytes, arena = session.arenaID
        guard try input.currentDocumentSelection() == selected,
          selected.focusUTF16 < session.logicalWindow.start.utf16 + session.logicalWindow.summary.utf16,
          selected.anchorUTF16 > session.logicalWindow.start.utf16 + session.logicalWindow.summary.utf16,
          selected.anchorUTF16 < before.source.summary.utf16,
          selected.utf16Length > UInt64(view.selectedRange().length),
          commands.queuedRawKeyCount == 0 else {
          throw BoomError.invalid("The first-key control requires a genuine partial nonresident selection.")
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6) else {
          throw BoomError.invalid("The actual first-key event is unavailable.")
        }
        // Same native turn: the MainActor preparation Task has not received an
        // async turn before the actual responder moves. This is a pre-entry
        // boundary, not the SDK control's held, entered backend completion.
        window.sendEvent(event)
        guard commands.queuedRawKeyCount == 1, commands.retainedInputBytes == retained + 514,
          commands.retainedRefusedInputCount == 0,
          try session.captureLogicalState().source.isSame(before.source),
          session.generation == before.generation, session.arenaID == arena else {
          throw BoomError.invalid("The real first key was not retained before its nonresident preparation.")
        }
        guard window.makeFirstResponder(other), window.firstResponder === other else {
          throw BoomError.unavailable("The actual first-key control could not move its responder.")
        }
        try await commands.joinPendingCommand(); try await viewport.joinPresentation()
        guard window.firstResponder === other, other.string == "Other", input.activeView === view,
          view.inputContext === context, !client.isRetired,
          commands.queuedRawKeyCount == 0, commands.retainedInputBytes == retained,
          commands.retainedRefusedInputCount == 0, commands.unretainedRawKeyCount == 0,
          session.generation == before.generation + 2,
          try input.currentDocumentSelection().utf16Offset == selected.utf16Offset + 1,
          try input.currentDocumentSelection().utf16Length == 0,
          try commands.captureLogicalHistory().undo.count == history.undo.count + 1 else {
          throw BoomError.invalid("The admitted original key was lost, retargeted, split or stole actual focus.")
        }
        let expected = (String(decoding: bytes, as: UTF8.self) as NSString)
          .replacingCharacters(in: NSRange(location: Int(selected.utf16Offset), length: Int(selected.utf16Length)), with: "z")
        try await requireDocumentInputSource(Data(expected.utf8))
        let after = try session.captureLogicalState().source
        guard window.makeFirstResponder(view), window.firstResponder === view else {
          throw BoomError.unavailable("The actual editor could not receive responder Undo after the focus control.")
        }
        try await mixedResponder(false, event: 0, measured: false)
        try await requireDocumentInputSource(bytes, root: original)
        guard try input.currentDocumentSelection() == selected else {
          throw BoomError.invalid("Responder Undo did not restore the original nonresident selection.")
        }
        try await mixedResponder(true, event: 0, measured: false)
        try await requireDocumentInputSource(Data(expected.utf8), root: after)
        guard try input.currentDocumentSelection().utf16Offset == selected.utf16Offset + 1 else {
          throw BoomError.invalid("Responder Redo lost the admitted original key's actual caret.")
        }
        try await mixedResponder(false, event: 0, measured: false)
        try await requireDocumentInputSource(bytes, root: original)
        guard input.firstRefusal == nil, commands.firstFailure == nil,
          view.boundedStorage.mutationFailure == nil, window.firstResponder === view else {
          throw BoomError.invalid("The first-key focus control left a refusal or lost its actual responder.")
        }
      } catch { let failure = await joinedDocumentInputFailure(error); throw failure }
    }

    private func applicationState(_ window: NSWindow) -> [String: Any] {
      ["running": NSApp.isRunning, "active": NSApp.isActive, "hidden": NSApp.isHidden,
        "activation_policy": NSApp.activationPolicy().rawValue,
        "actual_key_window": NSApp.keyWindow === window, "window_is_key": window.isKeyWindow,
        "window_visible": window.isVisible, "window_can_become_key": window.canBecomeKey,
        "frontmost_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
        "frontmost_bundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"]
    }

    // Real AppKit readiness, outside donation/timing and inside the existing
    // preparation deadline. Both readiness and deadline tasks actually join;
    // an absent notification never substitutes for the strict key-window test.
    private func receiveActualKeyWindow(_ window: NSWindow, within timeout: Duration = .seconds(5)) async throws {
      applicationBeforeFocus = applicationState(window)
      defer { applicationAfterFocus = applicationState(window) }
      if NSApp.isRunning, NSApp.isActive, window.isKeyWindow { return }
      let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let key = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
        object: window, queue: .main) { _ in continuation.yield(()) }
      let active = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
        object: NSApp, queue: .main) { _ in continuation.yield(()) }
      defer {
        NotificationCenter.default.removeObserver(key); NotificationCenter.default.removeObserver(active)
        continuation.finish()
      }
      try await withThrowingTaskGroup(of: Void.self) { group in
        defer { group.cancelAll() }
        group.addTask { @MainActor in
          if NSApp.isRunning, NSApp.isActive, window.isKeyWindow { return }
          for await _ in signals {
            try Task.checkCancellation()
            if NSApp.isRunning, NSApp.isActive, window.isKeyWindow { return }
          }
          throw CancellationError()
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw BoomError.unavailable("Actual public App/key-window readiness exceeded its bounded allowance: \(timeout).")
        }
        // This explicitly requested foreground fixture uses the same activation
        // request at startup and re-entry. It still requires observed readiness;
        // a locked desktop cannot satisfy the key-window checks above.
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await group.next()
      }
      guard NSApp.isRunning, NSApp.isActive, NSApp.keyWindow === window, window.isKeyWindow else {
        throw BoomError.unavailable("The actual public App did not retain its received key-window state.")
      }
    }

    /// Functional preparation only. All controls finish before stack donation
    /// or steady timing, and every actual writer/save Task joins on all paths.
    private func verifyHeldWriterEditing() async throws {
      guard let model = workspace, let engine = model.pagedEngine, let input = model.pagedInput,
        let viewport = model.pagedViewport, let commands = model.pagedCommands else {
        throw BoomError.invalid("Held writer control lost its actual ordinary owners.")
      }
      let view = try currentMixedView(), session = view.session
      let original = try commands.captureLogicalHistory().snapshot
      let savedGeneration = session.sealedGeneration
      let release = DispatchSemaphore(value: 0)
      let (signals, entered) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let executor = engine.storageExecutorForTesting
      let writer = Task {
        defer { entered.finish() }
        try await executor.run { entered.yield(()); release.wait() }
      }
      var failure: Error?
      do {
        try await withThrowingTaskGroup(of: Void.self) { group in
          defer { group.cancelAll() }
          group.addTask { @MainActor [self] in
            var iterator = signals.makeAsyncIterator()
            guard let _ = await iterator.next() else { throw BoomError.unavailable("Actual writer body did not enter.") }
            if normalMemory { recordGraphicsStage("held-writer-entered") }
            view.setSelectedRange(NSRange(location: 1, length: 0))
            let beforeSelection = try input.currentDocumentSelection()
            view.insertText("Xé🙂", replacementRange: view.selectedRange())
            let afterSelection = try input.currentDocumentSelection()
            let edited = try session.captureLogicalState().source, editedGeneration = session.generation
            heldSave = try model.beginPagedWorkspaceSave() // actual owned reservation, before yielding
            // Reservation precedes asynchronous command/save joins. Establish
            // the actual queued save before exercising input against the held
            // writer; the existing preparation deadline bounds this wait.
            while executor.snapshot.foregroundRequests < 2 {
              try Task.checkCancellation()
              try await Task.sleep(for: .milliseconds(1))
            }
            if normalMemory { recordGraphicsStage("held-writer-save-queued") }
            guard model.pagedInput === input, try currentMixedView().session === session,
              NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil),
              session.generation == editedGeneration + 1,
              try session.captureLogicalState().source.isSame(original),
              try input.currentDocumentSelection() == beforeSelection else {
              throw BoomError.invalid("Resident responder Undo waited or restored another logical source.")
            }
            _ = try currentMixedView() // actual physical focus after the resident Undo mount
            guard NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil),
              session.generation == editedGeneration + 2,
              try session.captureLogicalState().source.isSame(edited),
              try input.currentDocumentSelection() == afterSelection else {
              throw BoomError.invalid("Resident responder Redo waited or restored another logical source.")
            }
            if normalMemory { recordGraphicsStage("held-writer-redo") }
            let middle = edited.summary.utf16 / 2
            try viewport.requestScroll(toUTF16: middle); try await viewport.joinPresentation()
            if normalMemory { recordGraphicsStage("held-writer-middle-scroll") }
            let displayed = viewport.visibleScrollWindow, queue = executor.snapshot
            guard let displayed, displayed.snapshot.isSame(edited),
              displayed.start.utf16 <= middle, middle <= displayed.start.utf16 + displayed.summary.utf16,
              session.sealedGeneration == savedGeneration, queue.foregroundRequests >= 2 else {
              heldWriterFailureState = ["displayed_missing": displayed == nil,
                "displayed_root": displayed?.snapshot.rootID.uuidString ?? "nil",
                "edited_root": edited.rootID.uuidString,
                "displayed_is_edited": displayed?.snapshot.isSame(edited) ?? false,
                "displayed_start_utf16": displayed.map { $0.start.utf16 as Any } ?? NSNull(),
                "displayed_extent_utf16": displayed.map { $0.summary.utf16 as Any } ?? NSNull(),
                "requested_middle_utf16": middle, "edited_utf16": edited.summary.utf16,
                "sealed_generation": session.sealedGeneration, "captured_saved_generation": savedGeneration,
                "current_generation": session.generation,
                "foreground_requests": queue.foregroundRequests,
                "background_requests": queue.backgroundRequests, "cleanup_requests": queue.cleanupRequests]
              throw BoomError.invalid("Logical scroll or the real reserved save escaped the held writer condition.")
            }
            let acceptedArena = session.arenaID
            try input.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: 0,
              utf16Length: 30_000, focusAtEnd: false, affinity: .upstream))
            try viewport.requestScroll(toUTF16: 0); try await viewport.joinPresentation()
            if normalMemory { recordGraphicsStage("held-writer-head-scroll") }
            guard let head = viewport.visibleScrollWindow, head.start.utf16 == 0,
              head.snapshot.isSame(edited), head.text.hasPrefix("AXé🙂") else {
              throw BoomError.invalid("Actual dirty Unicode scroll did not retain its exact source under the held writer.")
            }
            try viewport.selectVisibleUTF16(5, extending: true)
            if normalMemory { recordGraphicsStage("held-writer-extended-selection") }
            let extended = try input.currentDocumentSelection()
            guard extended.utf16Offset == 5, extended.utf16Length == 29_995,
              extended.anchorUTF16 == 30_000, !extended.focusAtEnd, extended.affinity == .upstream,
              session.generation == editedGeneration + 2, session.arenaID == acceptedArena,
              session.activeNavigationOperationCount == 0, !commands.hasPendingCommand,
              viewport.visibleScrollWindow == nil, try currentMixedView() === view,
              session.sealedGeneration == savedGeneration, executor.snapshot.foregroundRequests >= 2 else {
              throw BoomError.invalid("Actual held-writer Shift click lost its global anchor or entered source navigation/save.")
            }
            heldScrollShiftVerified = true
            try viewport.requestScroll(toUTF16: 0); try await viewport.joinPresentation()
            try viewport.selectVisibleUTF16(5); try await commands.joinPendingCommand()
            let current = try currentMixedView(), beforeTyping = session.generation
            current.insertText("Y", replacementRange: current.selectedRange())
            guard session.generation == beforeTyping + 1, session.sealedGeneration == savedGeneration else {
              throw BoomError.invalid("Later native typing remained coupled to the actual held writer.")
            }
            guard NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil),
              try session.captureLogicalState().source.isSame(edited),
              NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil),
              try session.captureLogicalState().source.isSame(original),
              try input.currentDocumentSelection() == beforeSelection else {
              throw BoomError.invalid("Actual responder actions did not restore the original public source while saving.")
            }
            managedEditor = try currentMixedView()
            if normalMemory { recordGraphicsStage("held-writer-restored-source") }
          }
          group.addTask {
            try await Task.sleep(for: .seconds(8))
            release.signal(); entered.finish() // release so an entered/coupled read can actually join
            throw BoomError.unavailable("Held-writer native/read control exceeded its fixed8s bound.")
          }
          try await group.next()
        }
      } catch { failure = error }
      release.signal(); entered.finish()
      do { try await writer.value } catch {
        if let first = failure { failure = BoomError.unavailable(first.localizedDescription + "; actual writer join: " + error.localizedDescription) }
        else { failure = error }
      }
      do { if let heldSave { try await heldSave.value } } catch {
        if let first = failure { failure = BoomError.unavailable(first.localizedDescription + "; actual save join: " + error.localizedDescription) }
        else { failure = error }
      }
      if normalMemory { recordGraphicsStage("held-writer-joined") }
      if let failure { throw failure }
      try await model.flush(); managedEditor = model.pagedInput?.activeView
      try await verifyOrdinaryExport(named: "held-save-export.txt")
      if normalMemory { recordGraphicsStage("held-writer-export") }
      try requireManagedSource(); heldWriterVerified = true; heldSave = nil
    }

    // Functional preparation only; this port uses the existing public72K
    // graph and actual production backup Tasks, before any timing/donation.
    private func verifyLiveBackupControls() async throws {
      guard plan.utf8Bytes == 72_196, let model = workspace, let window,
        let engine = model.pagedEngine, let session = model.pagedSession,
        let input = model.pagedInput, let commands = model.pagedCommands,
        let viewport = model.pagedViewport, let documentID else {
        throw BoomError.invalid("Public backup controls lost their fixed ordinary graph.")
      }
      let scratch = root.appendingPathComponent("backup-controls", isDirectory: true)
      guard mkdir(scratch.path, 0o700) == 0 else { throw BoomError.invalid("Backup control scratch is not fresh.") }
      backupPhaseActive = true
      try await verifyCancelledBackup(model: model, scratch: scratch)
      try await mixedCaret(0, event: 0, measured: false)
      let original = try commands.captureLogicalHistory().snapshot, originalDraft = model.draft
      let view = try currentMixedView(), manager = commands.manager
      let context = view.inputContext, vault = model.store.vault
      let attachmentID = UUID(), attachmentBytes = Data("Public backup attachment".utf8)
      view.insertText("é🙂", replacementRange: view.selectedRange())
      model.draft = "Snapshot owner draft"
      try await detachedWork { try vault.put(attachmentBytes, kind: .attachment, id: attachmentID) }
      try await commands.joinPendingCommand(); try await model.flush()
      guard let captured = model.pagedSelectedRecord else { throw BoomError.invalid("Backup source record is absent.") }
      let capturedSelection = try input.currentDocumentSelection()
      let capturedDigest = try await engine.wholeTextSha256(captured.document.revision)
      guard captured.document.revision.summary.bytes == plan.utf8Bytes + 6 else {
        throw BoomError.invalid("Public backup source edit has another extent.")
      }
      let backup = scratch.appendingPathComponent("snapshot")
      let hold = DeveloperBackupCopyHold(documentID: documentID)
      defer { hold.release() }
      _ = try diskExtent(reservingReceipt: true, forBackupPreparation: true,
        reservingWorkspaceCopies: 2, reservingDirectories: 1)
      let export = try model.exportWorkspaceBackup(to: backup, progress: { try hold.copied($0, $1, $2) }, temporaryParent: scratch)
      var exportJoined = false
      do {
        backupControlStage = "live-copy-held"
        let files = try await receiveBackupHold(hold)
        _ = try diskExtent(reservingReceipt: true, forBackupPreparation: true)
        guard files.bytes == 65_536, model.pagedEngine === engine, model.pagedSession === session,
          model.pagedInput === input, model.pagedViewport === viewport, model.pagedCommands === commands,
          input.activeView === view, view.inputContext === context, commands.manager === manager,
          window.firstResponder === view, window.isKeyWindow, view.isEditable, !model.isBusy,
          !FileManager.default.fileExists(atPath: backup.path) else {
          throw BoomError.invalid("Actual live clone copy changed its native graph or focus.")
        }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("X", replacementRange: view.selectedRange())
        try await commands.joinPendingCommand(); try await model.flush()
        guard session.sealedGeneration == session.generation,
          session.sealedRootRecord.document.revision.summary.bytes == captured.document.revision.summary.bytes + 1,
          try currentMixedView().string.hasPrefix("Xé🙂"), hold.isHeld else {
          throw BoomError.invalid("Actual live publication did not complete while clone copy was held.")
        }
        try await mixedResponder(false, event: 0, measured: false)
        guard try session.captureLogicalState().source.summary.bytes == captured.document.revision.summary.bytes,
          try currentMixedView().string.hasPrefix("é🙂"), hold.isHeld else {
          throw BoomError.invalid("Actual key responder Undo failed while clone copy was held.")
        }
        try await mixedResponder(true, event: 0, measured: false)
        let redone = try currentMixedView()
        guard redone.string.hasPrefix("Xé🙂"), redone.undoManager === manager,
          model.pagedEngine === engine, model.pagedSession === session, model.pagedInput === input,
          model.pagedViewport === viewport, model.pagedCommands === commands, hold.isHeld else {
          throw BoomError.invalid("Actual key responder Redo changed the backup's live graph.")
        }
        model.draft = "Later owner draft"
        try await detachedWork { try vault.put(Data("Later attachment bytes".utf8), kind: .attachment, id: attachmentID) }
        try await model.flush()
        redone.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0),
          replacementRange: NSRange(location: NSNotFound, length: 0))
        guard redone.hasMarkedText(), session.isPinned else { throw BoomError.invalid("Actual backup composition did not enter.") }
        let anchor = try session.documentCoordinates().projectedUTF16 - 4
        try viewport.requestScroll(toUTF16: anchor); try await viewport.joinPresentation()
        guard let tail = viewport.visibleScrollWindow,
          tail.snapshot.isSame(try session.captureLogicalRead().source), tail.text.utf8.count <= 16_384,
          tail.start.utf16 <= anchor, tail.start.utf16 + tail.summary.utf16 >= anchor,
          redone.hasMarkedText(), session.isPinned, window.firstResponder === redone,
          window.isKeyWindow, hold.isHeld else {
          throw BoomError.invalid("Actual marked live scroll did not complete while clone copy was held.")
        }
        redone.unmarkText(); try await commands.joinPendingCommand(); try await model.flush()
        guard try currentMixedView().string.hasPrefix("X漢é🙂"), hold.isHeld else {
          throw BoomError.invalid("Actual backup composition did not retain its text before copy release.")
        }
        hold.release(); exportJoined = true
        guard try await export.value == backup, !hold.didTimeOut else {
          throw BoomError.invalid("Actual clone export did not join its published destination.")
        }
      } catch {
        let original = error; hold.release()
        if !exportJoined, case .failure(let cleanup) = await export.result {
          throw BoomError.unavailable(original.localizedDescription + "; actual backup join: " + cleanup.localizedDescription)
        }
        throw original
      }

      backupCapturedRecord = captured; backupCapturedSelection = capturedSelection
      backupCapturedDigest = capturedDigest; backupAttachmentID = attachmentID
      backupOriginalIncarnation = session.engineIncarnation; backupOriginalSessionID = session.sessionID
      try await mixedResponder(false, event: 0, measured: false) // 漢
      try await mixedResponder(false, event: 0, measured: false) // X
      try await mixedResponder(false, event: 0, measured: false) // é🙂
      guard try commands.captureLogicalHistory().snapshot.isSame(original) else {
        throw BoomError.invalid("Live backup controls did not restore the original logical source.")
      }
      model.draft = originalDraft; try await model.flush()
      try await detachedWork { try FileManager.default.removeItem(at: vault.recordURL(.attachment, attachmentID)) }
      try await verifyOrdinaryExport(named: "backup-baseline-export.txt")
      liveBackupVerified = true; backupPhaseActive = false
      backupControlStage = "await-original-close"
    }

    // The real original shutdown must release the sole Engine slot first.
    private func verifyColdBackupRestore() async throws {
      guard backupOriginalClosed else {
        throw BoomError.invalid("Cold backup restore lacks its actually closed original graph/snapshot.")
      }
      backupPhaseActive = true
      do { try await receiveColdBackupRestore() }
      catch {
        let original = error
        if backupRestored != nil, !backupRestoreCloseAttempted {
          do { try await closeBackupRestoredGraph() }
          catch { throw BoomError.unavailable(original.localizedDescription + "; actual restored close: " + error.localizedDescription) }
        }
        throw original
      }
    }

    private func receiveColdBackupRestore() async throws {
      guard let captured = backupCapturedRecord, let capturedSelection = backupCapturedSelection,
        let capturedDigest = backupCapturedDigest, let attachmentID = backupAttachmentID,
        let documentID, let expectedDigest, let backupOriginalIncarnation, let backupOriginalSessionID else {
        throw BoomError.invalid("Cold backup restore lost its retained snapshot fields.")
      }
      let scratch = root.appendingPathComponent("backup-controls", isDirectory: true)
      let backup = scratch.appendingPathComponent("snapshot"), restoredRoot = scratch.appendingPathComponent("restored")
      let attachmentBytes = Data("Public backup attachment".utf8)
      backupControlStage = "cold-restore"
      _ = try diskExtent(reservingReceipt: true, forBackupPreparation: true,
        reservingWorkspaceCopies: 1, reservingDirectories: 2, copyingBackupSnapshot: true)
      let restoredStore = try WorkspaceStore(rootOverride: restoredRoot)
      try await restoredStore.restoreBackup(from: backup)
      let restored: WorkspaceModel
      do { restored = try await WorkspaceModel(storeOverride: restoredStore, loadModels: false) }
      catch let failure as WorkspacePagedStartupFailure { backupRestored = failure.model; throw failure.original }
      backupRestored = restored
      restored.setAutocomplete(false)
      let restoredWindow = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 846))
      backupRestoredWindow = restoredWindow; restoredWindow.isReleasedWhenClosed = false
      let restoredHost = NSHostingView(rootView: WorkspaceView(model: restored))
      backupRestoredHost = restoredHost; restoredWindow.contentView = restoredHost
      DeveloperEditorFixture.placeDiagnosticWindowOnRight(restoredWindow)
      for _ in 0..<10 { restoredHost.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
      try await receiveActualKeyWindow(restoredWindow)
      guard let restoredInput = restored.pagedInput, let restoredView = restoredInput.activeView,
        let restoredEngine = restored.pagedEngine, let restoredSession = restored.pagedSession,
        let restoredCommands = restored.pagedCommands,
        restoredSession.engineIncarnation != backupOriginalIncarnation,
        restoredSession.sessionID != backupOriginalSessionID,
        restoredView.window === restoredWindow, restoredWindow.makeFirstResponder(restoredView),
        restoredWindow.firstResponder === restoredView, restoredWindow.isKeyWindow,
        restored.pagedSelectedRecord == captured,
        try restoredInput.currentDocumentSelection() == capturedSelection,
        restored.draft == "Snapshot owner draft" else {
        throw BoomError.invalid("Actual cold backup graph/source/cursor/draft differs from its captured snapshot.")
      }
      let restoredAttachment = try await detachedWork { try restoredStore.vault.get(.attachment, id: attachmentID) }
      let restoredDigest = try await restoredEngine.wholeTextSha256(captured.document.revision)
      guard let imported = restored.state.importedFiles?[documentID]?.originalRevision else {
        throw BoomError.invalid("Cold backup lost its actual imported original revision.")
      }
      let originalDigest = try await restoredEngine.wholeTextSha256(imported)
      guard restoredAttachment == attachmentBytes, restoredDigest == capturedDigest,
        originalDigest == expectedDigest.map({ String(format: "%02x", $0) }).joined(),
        imported.summary.bytes == plan.utf8Bytes, restoredCommands.manager.canUndo,
        NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil) else {
        throw BoomError.invalid("Cold backup bytes/original source or actual responder Undo differs.")
      }
      try await restoredCommands.joinPendingCommand(); try await restored.flush()
      guard let restoredBefore = restored.pagedSelectedRecord else { throw BoomError.invalid("Cold restored Undo has no source record.") }
      let restoredBeforeDigest = try await restoredEngine.wholeTextSha256(restoredBefore.document.revision)
      guard restoredBeforeDigest == originalDigest else { throw BoomError.invalid("Cold backup Undo did not restore its complete original bytes.") }
      try await closeBackupRestoredGraph()
      _ = try diskExtent(reservingReceipt: true, forBackupPreparation: true)
      try await detachedWork { try FileManager.default.removeItem(at: scratch) }
      backupColdRestoreVerified = true; backupPhaseActive = false; backupControlStage = "complete"
    }

    private func receiveBackupHold(_ hold: DeveloperBackupCopyHold) async throws -> (source: URL, staged: URL, bytes: UInt64) {
      try await withThrowingTaskGroup(of: Void.self) { group in
        defer { group.cancelAll() }
        group.addTask {
          var iterator = hold.signals.makeAsyncIterator()
          guard let _ = await iterator.next() else { throw BoomError.unavailable("Actual backup copy did not enter its hold.") }
        }
        group.addTask {
          try await Task.sleep(for: .seconds(10)); hold.release()
          throw BoomError.unavailable("Actual backup copy did not enter within its fixed10s preparation bound.")
        }
        try await group.next()
      }
      guard hold.isHeld, let files = hold.actualFiles else { throw BoomError.invalid("Actual backup hold has no completed byte-copy observation.") }
      return files
    }

    private func closeBackupRestoredGraph() async throws {
      guard let restored = backupRestored else { return }
      guard !backupRestoreCloseAttempted else { throw BoomError.unavailable("A failed restored graph close remains retained; no close retry.") }
      backupRestoreCloseAttempted = true
      try await restored.shutdown()
      backupRestoredWindow?.close()
      backupRestored = nil; backupRestoredHost = nil; backupRestoredWindow = nil
    }

    private func verifyCancelledBackup(model: WorkspaceModel, scratch: URL) async throws {
      guard let engine = model.pagedEngine, let session = model.pagedSession, let input = model.pagedInput,
        let commands = model.pagedCommands, let viewport = model.pagedViewport, let documentID else {
        throw BoomError.invalid("Backup cancellation lost its ordinary graph.")
      }
      let original = try commands.captureLogicalHistory().snapshot
      let refused = scratch.appendingPathComponent("chosen-directory"), sentinel = refused.appendingPathComponent("retained")
      let sentinelBytes = Data("Retained chosen directory".utf8)
      try await detachedWork {
        try FileManager.default.createDirectory(at: refused, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]); try sentinelBytes.write(to: sentinel)
      }
      let unrelated = try model.exportPagedDocument(to: refused)
      let unrelatedFailure: Error
      switch await unrelated.result {
      case .success:
        throw BoomError.invalid("Actual chosen-directory export unexpectedly succeeded.")
      case .failure(let error): unrelatedFailure = error
      }
      guard let refusal = unrelatedFailure as? BoomError,
        case .denied(let reason) = refusal, reason == "Export cannot replace a symlink, directory or device." else {
        let native = unrelatedFailure as NSError
        let detail = String(decoding: native.localizedDescription.utf8.prefix(512), as: UTF8.self)
        let domain = String(decoding: native.domain.utf8.prefix(128), as: UTF8.self)
        let type = String(decoding: String(reflecting: Swift.type(of: unrelatedFailure)).utf8.prefix(160), as: UTF8.self)
        let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError
        throw BoomError.invalid("Actual chosen-directory export did not preserve its expected refusal: type=\(type), domain=\(domain), code=\(native.code), underlying=\(underlying?.code.description ?? "none"); \(detail)")
      }
      model.dismissError()
      let backup = scratch.appendingPathComponent("retry"), hold = DeveloperBackupCopyHold(documentID: documentID)
      defer { hold.release() }
      _ = try diskExtent(reservingReceipt: true, forBackupPreparation: true,
        reservingWorkspaceCopies: 2, reservingDirectories: 1)
      let cancelled = try model.exportWorkspaceBackup(to: backup, progress: { try hold.copied($0, $1, $2) }, temporaryParent: scratch)
      var cancelledJoined = false
      do {
        backupControlStage = "cancel-copy-held"
        let files = try await receiveBackupHold(hold)
        _ = try diskExtent(reservingReceipt: true, forBackupPreparation: true)
        let clone = files.source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let container = clone.deletingLastPathComponent()
        let stage = files.staged.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard files.bytes == 65_536, clone.lastPathComponent == "Workspace",
          stage.lastPathComponent.hasPrefix(".backup-"), hold.isHeld,
          model.pagedEngine === engine, model.pagedSession === session, model.pagedInput === input,
          model.pagedCommands === commands, model.pagedViewport === viewport else {
          throw BoomError.invalid("Actual backup retry was poisoned by unrelated export or changed its graph.")
        }
        let view = try currentMixedView()
        view.setSelectedRange(NSRange(location: 0, length: 0)); view.insertText("Y", replacementRange: view.selectedRange())
        try await commands.joinPendingCommand(); try await model.flush()
        guard let later = model.pagedSelectedRecord, try currentMixedView().string.hasPrefix("Y"), hold.isHeld else {
          throw BoomError.invalid("Actual later input/save did not finish before cancelling clone copy.")
        }
        model.cancelExport(to: backup); hold.release(); cancelledJoined = true
        guard case .failure(let cancellation) = await cancelled.result, cancellation is CancellationError,
          !hold.didTimeOut, !FileManager.default.fileExists(atPath: backup.path),
          !FileManager.default.fileExists(atPath: stage.path),
          !FileManager.default.fileExists(atPath: container.path) else {
          throw BoomError.invalid("Actual cancelled clone export did not join cancellation and clean only its files.")
        }
        _ = try diskExtent(reservingReceipt: true, forBackupPreparation: true,
          reservingWorkspaceCopies: 2, reservingDirectories: 1)
        let retry = try model.exportWorkspaceBackup(to: backup, temporaryParent: scratch)
        guard try await retry.value == backup else { throw BoomError.invalid("Actual backup retry returned another destination.") }
        let copiedRoot = try await detachedWork {
          let path = backup.appendingPathComponent("documents/" + documentID.uuidString.lowercased() + "/document-root.json")
          let value = try JSONDecoder().decode(PagedDocumentRootRecord.self, from: RegularFile(path, limit: 16_384).data())
          try value.validate(); return value
        }
        guard copiedRoot == later, case .failure(let retained) = await unrelated.result,
          (retained as NSError).domain == (unrelatedFailure as NSError).domain,
          (retained as NSError).code == (unrelatedFailure as NSError).code,
          retained.localizedDescription == unrelatedFailure.localizedDescription,
          try await detachedWork(operation: { try RegularFile(sentinel, limit: 4_096).data() }) == sentinelBytes else {
          throw BoomError.invalid("Actual backup retry differs or replaced the original retained export failure/files.")
        }
      } catch {
        let original = error; hold.release()
        if !cancelledJoined, case .failure(let cleanup) = await cancelled.result, !(cleanup is CancellationError) {
          throw BoomError.unavailable(original.localizedDescription + "; actual cancelled backup join: " + cleanup.localizedDescription)
        }
        throw original
      }
      try await mixedResponder(false, event: 0, measured: false)
      guard try commands.captureLogicalHistory().snapshot.isSame(original) else {
        throw BoomError.invalid("Backup cancellation control did not restore its actual prior source.")
      }
      try await model.flush()
      try await detachedWork {
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.removeItem(at: refused)
      }
      cancelledBackupVerified = true
    }

    func writeNormalMemorySummary(maximumSampledCurrent: UInt64, kernelLifetimePeak: UInt64, samples: Int) throws {
      guard normalMemory, maximumSampledCurrent > 0, kernelLifetimePeak >= maximumSampledCurrent,
        (1...40_000).contains(samples), normalTimings.count <= Int(plan.operations) else { throw BoomError.invalid("Normal observations exceed their fixed recipe.") }
      try JSONSerialization.data(withJSONObject: normalTimings, options: [.sortedKeys])
        .write(to: root.appendingPathComponent("typing-observations.json"), options: .withoutOverwriting)
      let value: [String: Any] = ["schema": 1, "normal_release": true, "model_free": true,
        "sample_interval_ms": 20, "samples": samples,
        "maximum_sampled_current_footprint_bytes": maximumSampledCurrent,
        "kernel_lifetime_peak_footprint_bytes": kernelLifetimePeak,
        "scope": "Normal App/file/native graph. Unsuspended scheduled paired input and synchronous layout; no cached-view raster in the timed input loop, Mach stack capture, forced draw/compositor or GPU inference. Post-loop verification encodes a 72x42 clipboard bitmap while sampling continues. After successful shutdown the fixture releases its graph and samples one more second. Memory probe overhead is included; setup/exports are distinct phases."]
      try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        .write(to: root.appendingPathComponent("memory-summary.json"), options: .withoutOverwriting)
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
      // The 100 ms scheduled cadence already consumes at least 100 seconds.
      // Normal unsuspended App runs need room for scheduler delay; the owned
      // stack recipe retains its tighter fixed observation deadline.
      let observationSeconds = normalMemory ? Self.normalObservationSeconds : Self.observationSeconds
      let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(observationSeconds))
      for index in 0..<requested.operations {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw BoomError.unavailable("Public editor observation exceeded its bound.") }
        let requested = clock.now.advanced(by: .milliseconds(100))
        try await Task.sleep(until: requested, clock: clock)
        guard clock.now < deadline else { throw BoomError.unavailable("Public editor observation expired before its next cycle.") }
        let priorGeneration = view.session.generation
        do {
          let cycle = PerformanceTrace.begin("Editor.PublicTypingCycle", event: UInt64(index) + 1)
          defer { PerformanceTrace.end("Editor.PublicTypingCycle", cycle) }
          let started = clock.now
          view.setSelectedRange(NSRange(location: 0, length: 0))
          view.insertText("x", replacementRange: view.selectedRange())
          let inserted = clock.now
          view.insertText("", replacementRange: NSRange(location: 0, length: 1))
          let deleted = clock.now
          let layout = PerformanceTrace.begin("Editor.HostLayout")
          host.layoutSubtreeIfNeeded()
          PerformanceTrace.end("Editor.HostLayout", layout)
          let laidOut = clock.now
          if !normalMemory { try rasterize(view) } // stack recipe retains actual cached-bitmap completion
          if normalMemory {
            normalTimings.append(["event": index + 1,
              "scheduled_delay_seconds": max(0, requested.duration(to: started).timeInterval),
              "insertion_seconds": started.duration(to: inserted).timeInterval,
              "deletion_seconds": inserted.duration(to: deleted).timeInterval,
              "layout_seconds": deleted.duration(to: laidOut).timeInterval,
              "admitted_input_to_layout_seconds": started.duration(to: laidOut).timeInterval])
          }
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
        // The accepted guard stays exact. Name its failed relationship only
        // on refusal; no body, stack collection or IO enters a measured cycle.
        let active = workspace?.pagedInput?.activeView
        var missing: [String] = []
        if workspace == nil { missing.append("model") }
        if active == nil { missing.append("active-view") }
        if let active, workspace?.pagedViewport?.textView !== active { missing.append("viewport-view") }
        if window == nil { missing.append("window") }
        if let active, let window {
          if window.firstResponder !== active { missing.append("first-responder") }
          if !window.isKeyWindow { missing.append("key-window") }
          if active.window !== window { missing.append("attached-window") }
        }
        let responder = window?.firstResponder.map { String(String(reflecting: type(of: $0)).prefix(96)) } ?? "nil"
        let slot = lastWarmSlot.map(String.init) ?? "none"
        let application = window.map { String(describing: applicationState($0)) } ?? "no-window"
        throw BoomError.stale("Mixed observation lost its actual mounted key-window client [" +
          missing.joined(separator: ",") + "]; warm-slot=" + slot + "; responder=" + responder + "; application=" + application + ".")
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
      guard let model = workspace, let commands = model.pagedCommands, let viewport = model.pagedViewport else {
        throw BoomError.stale("Mixed input lost its existing command owner.")
      }
      try await mixedReady(event, measured: measured) {
        try await commands.joinPendingCommand()
        try await viewport.joinPresentation()
        // Warm controls retain durable checkpoints. Measured UI readiness
        // joins actual commands/presentation; final save/export stays outside.
        if !measured { try await model.flush() }
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

    private func recordWarmMarkedState(_ label: String) {
      guard warmMarkedStates.count < 11, let model = workspace,
        let view = model.pagedInput?.activeView, let commands = model.pagedCommands else { return }
      var value: [String: Any] = ["step": label, "generation": view.session.generation,
        "pinned": view.session.isPinned, "marked": view.hasMarkedText(),
        "storage_group": view.boundedStorage.currentNativeGroupID.uuidString,
        "native_selection_location": view.selectedRange().location,
        "native_selection_length": view.selectedRange().length]
      do {
        let history = try commands.captureLogicalHistory()
        value["root"] = history.snapshot.rootID.uuidString
        value["bytes"] = history.snapshot.summary.bytes; value["utf16"] = history.snapshot.summary.utf16
        value["active_group"] = history.activeGroup?.uuidString ?? "nil"
        value["undo_count"] = history.undo.count; value["redo_count"] = history.redo.count
        func entries(_ values: [PagedNativeLogicalHistoryEntry]) -> [[String: Any]] {
          values.suffix(2).map { ["group": $0.groupID.uuidString, "root": $0.snapshot.rootID.uuidString,
            "bytes": $0.snapshot.summary.bytes, "utf16": $0.snapshot.summary.utf16] }
        }
        value["undo_tail"] = entries(history.undo); value["redo_tail"] = entries(history.redo)
      } catch {
        value["observation_error"] = String(decoding: error.localizedDescription.utf8.prefix(512), as: UTF8.self)
      }
      warmMarkedStates.append(value)
    }

    private func mixedRestoreEdit(event: UInt64, measured: Bool, observeMarkedWarm: Bool = false) async throws {
      if observeMarkedWarm { recordWarmMarkedState("before-undo") }
      try await mixedResponder(false, event: event, measured: measured)
      if observeMarkedWarm { recordWarmMarkedState("after-undo") }
      try await mixedResponder(true, event: event, measured: measured)
      if observeMarkedWarm { recordWarmMarkedState("after-redo") }
      try await mixedResponder(false, event: event, measured: measured)
      if observeMarkedWarm { recordWarmMarkedState("after-final-undo") }
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
        if !measured { recordWarmMarkedState("after-nfd-zwj-insert") }
        try renderMixedSurface(event: event, measured: measured)
        for deletion in 0..<2 {
          try mixedCPU(event, measured: measured) {
            try currentMixedView().doCommand(by: NSSelectorFromString("deleteBackward:"))
          }
          try await joinMixedInput(event, measured: measured)
          if !measured { recordWarmMarkedState(deletion == 0 ? "after-zwj-delete" : "after-nfd-delete") }
        }
      case 7:
        if !measured { recordWarmMarkedState("before-marked") }
        try mixedCPU(event, measured: measured) {
          let view = try currentMixedView(), unspecified = NSRange(location: NSNotFound, length: 0)
          view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
          guard view.hasMarkedText() else { throw BoomError.invalid("The native marked-text input was not pinned.") }
          if !measured { recordWarmMarkedState("after-first-marked") }
          view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecified)
          if !measured { recordWarmMarkedState("after-marked-update") }
          let marked = view.markedRange()
          view.unmarkText()
          if !measured { recordWarmMarkedState("after-unmark") }
          let text = view.boundedStorage.string as NSString
          guard !view.hasMarkedText(), marked.location != NSNotFound,
            marked.length == 2, NSMaxRange(marked) <= text.length,
            text.substring(with: marked) == "日本" else {
            throw BoomError.invalid("The native marked-text input did not retain its committed characters.")
          }
        }
        try await joinMixedInput(event, measured: measured)
        try renderMixedSurface(event: event, measured: measured)
        try await mixedRestoreEdit(event: event, measured: measured, observeMarkedWarm: !measured)
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
        guard try input.currentDocumentSelection().utf16Offset == displayed.start.utf16 + UInt64(local) else {
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
        try input.session.captureLogicalState().source.summary.bytes == extent else {
        throw BoomError.invalid("Mixed operation did not retain its graph or restored source extent.")
      }
    }

    // A genuine readiness acquisition between operations is not an input
    // retry. The existing110s observation deadline includes every such gap.
    private func receiveMixedReadiness(event: UInt64) async throws {
      guard let model = workspace, let input = model.pagedInput,
        let commands = model.pagedCommands, let viewport = model.pagedViewport,
        let window, let host, let view = input.activeView,
        viewport.textView === view, view.window === window, window.firstResponder === view else {
        throw BoomError.stale("Mixed readiness lost its actual mounted graph or responder before activation.")
      }
      if NSApp.isRunning, NSApp.isActive, NSApp.keyWindow === window, window.isKeyWindow { return }
      managedEditor = view; try requireManagedSource()
      let session = input.session, before = try session.captureLogicalState()
      let selection = try input.currentDocumentSelection(), nativeRange = view.selectedRange()
      let affinity = view.selectionAffinity, binding = input.activeIdentity
      let start = ContinuousClock().now
      reactivationCount += 1; lastReactivationEvent = event
      defer {
        let elapsed = start.duration(to: ContinuousClock().now).timeInterval
        reactivationTotalSeconds += elapsed
        reactivationMaximumSeconds = max(reactivationMaximumSeconds, elapsed)
      }
      try await receiveActualKeyWindow(window)
      guard workspace === model, self.host === host, self.window === window,
        model.pagedInput === input, model.pagedSession === session,
        model.pagedCommands === commands, model.pagedViewport === viewport,
        input.activeView === view, viewport.textView === view, input.activeIdentity == binding,
        session.isCurrent(before), try input.currentDocumentSelection() == selection,
        view.selectedRange() == nativeRange, view.selectionAffinity == affinity,
        window.firstResponder === view, window.isKeyWindow, NSApp.keyWindow === window else {
        throw BoomError.stale("Actual readiness re-entry changed the graph/source/generation/selection; no input was retried.")
      }
      try requireManagedSource()
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
      let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(Self.observationSeconds))
      try await receiveMixedReadiness(event: 0)
      _ = try currentMixedView()
      footprintBefore = ModelResidency.memoryAccounting().current
      guard footprintBefore > 0 else { throw BoomError.unavailable("Public process footprint is unavailable.") }
      for index in 0..<requested.operations {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw BoomError.unavailable("Mixed observation exceeded its fixed bound.") }
        try await Task.sleep(until: clock.now.advanced(by: .milliseconds(250)), clock: clock)
        guard clock.now < deadline else { throw BoomError.unavailable("Mixed observation expired before its next operation.") }
        try await receiveMixedReadiness(event: UInt64(index) + 1)
        guard clock.now < deadline else { throw BoomError.unavailable("Mixed readiness consumed the fixed observation deadline; no input was retried.") }
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
            let count = try autoreleasepool {
              guard let block = try file.read(upToCount: Int(min(UInt64(64 << 10), extent - consumed))), !block.isEmpty else {
                throw BoomError.invalid("Public export ended before its admitted extent.")
              }
              hash.update(data: block)
              return UInt64(block.count)
            }
            consumed += count
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

    // Existing signed App.run verification only, after timing/capture closes.
    // The actual product viewport performs the initial head request; no observer
    // is removed and no competing cold markup operation is invented.
    private func verifyVisibleDemandMarkup(original: PagedNativeLogicalSnapshot, bytes: Data) async throws {
      guard let model = workspace, let engine = model.pagedEngine, let session = model.pagedSession,
        let input = model.pagedInput, let commands = model.pagedCommands, let viewport = model.pagedViewport,
        let firstByte = bytes.first, firstByte < 0x80 else {
        throw BoomError.invalid("Visible-demand verification lost its fixed public source/owners.")
      }
      let text = "# **Head 🙂**\n\n" + String(repeating: "ordinary paragraph\n\n", count: 2600)
        + "# **Tail é🙂**\nΩ"
      let replacement = Data(text.utf8)
      guard bytes.count + replacement.count <= PagedCapturedEditInput.maximumInputBytes else {
        throw BoomError.budget("The short verification edits exceed their actual captured-byte bound.")
      }
      try await mixedCaret(0, event: 0, measured: false)
      try await model.flush(); await viewport.joinMarkup()
      guard let record = model.pagedSelectedRecord else { throw BoomError.stale("The actual verification checkpoint is absent.") }
      let windowID = session.logicalWindow.windowID
      // Two exact descending edits make one real SDK group and leave its
      // caret at0. The final non-ASCII scalar cannot reuse the ASCII old tail.
      _ = try await commands.applyCapturedEdits(expected: record, edits: [
        PagedTextLocalEdit(revision: record.document.revision, windowID: windowID,
          byteStart: 1, byteEnd: UInt64(bytes.count), oldBytes: Data(bytes.dropFirst()), newBytes: replacement),
        PagedTextLocalEdit(revision: record.document.revision, windowID: windowID,
          byteStart: 0, byteEnd: 1, oldBytes: Data([firstByte]), newBytes: Data()),
      ], actionName: "Public markup verification")
      managedEditor = input.activeView
      try await model.flush(); await viewport.joinMarkup()
      guard viewport.markupFailure == nil, session.logicalWindow.start.utf16 == 0 else {
        throw BoomError.invalid("The actual product head request did not finish at its cold source origin.")
      }
      try await requireDocumentInputSource(replacement)
      let read = try session.captureLogicalRead(), head = session.logicalWindow
      let generation = session.generation, arena = session.arenaID, version = try currentMixedView().sourceVersion
      let custody = engine.custodySnapshot, whole: [MarkdownSpan] = try ProductCore.markdownSpans(text)
      let ordered: ([MarkdownSpan]) -> [MarkdownSpan] = { rows in
        rows.sorted { ($0.location, $0.length, $0.kind, $0.level) < ($1.location, $1.length, $1.kind, $1.level) }
      }
      let expected: (PagedNativeLogicalWindow) -> [MarkdownSpan] = { window in
        let first = Int(window.start.utf16), last = Int(window.start.utf16 + window.summary.utf16)
        return ordered(whole.compactMap { span -> MarkdownSpan? in
          let lower = max(first, span.location), upper = min(last, span.location + span.length)
          return lower < upper ? MarkdownSpan(kind: span.kind, location: lower - first,
            length: upper - lower, level: span.level) : nil
        })
      }
      let first = try await engine.logicalMarkup(head)
      guard first.matches(head), first.style.complete, first.media.complete,
        ordered(first.style.markdown) == expected(head) else {
        throw BoomError.invalid("Actual head context differs from the complete native Core oracle.")
      }
      let afterHead = try await engine.fileStatistics(), release = DispatchSemaphore(value: 0)
      let (signals, entered) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let executor = engine.storageExecutorForTesting
      let writer = Task {
        defer { entered.finish() }
        try await executor.run {
          entered.yield(())
          guard release.wait(timeout: .now() + 10) == .success else {
            throw BoomError.unavailable("Actual markup verification writer hold exceeded10s.")
          }
        }
      }
      var repeated: PagedNativeMarkupProjection?, failure: Error?
      do {
        repeated = try await withThrowingTaskGroup(of: PagedNativeMarkupProjection?.self) { group in
          defer { group.cancelAll() }
          group.addTask { @MainActor in
            var iterator = signals.makeAsyncIterator()
            guard let _ = await iterator.next() else { throw BoomError.unavailable("The actual markup writer did not enter.") }
            return try await engine.logicalMarkup(head)
          }
          group.addTask {
            try await Task.sleep(for: .seconds(5))
            release.signal(); entered.finish()
            throw BoomError.unavailable("An already-covered exact prefix waited on the held writer.")
          }
          guard let value = try await group.next() else { throw BoomError.unavailable("The actual prefix query did not join.") }
          return value
        }
      } catch { failure = error }
      release.signal(); entered.finish()
      do { try await writer.value } catch {
        if let original = failure { failure = DeveloperInputControlFailure(original: original, cleanup: error) }
        else { failure = error }
      }
      if let failure { throw failure }
      guard let repeated, repeated.matches(head), repeated.style.complete, repeated.media.complete,
        ordered(repeated.style.markdown) == expected(head) else {
        throw BoomError.invalid("The exact repeated prefix lost its actual complete projection.")
      }
      let afterRepeat = try await engine.fileStatistics()
      guard afterRepeat.appendedPages == afterHead.appendedPages, afterRepeat.appendedBytes == afterHead.appendedBytes else {
        throw BoomError.invalid("An unchanged exact prefix appended new derived pages.")
      }
      let tail = try await engine.logicalWindow(read.source, utf16Anchor: read.source.summary.utf16,
        maximumBytes: PagedWorkingWindow.targetBytes)
      let continued = try await engine.logicalMarkup(tail), afterTail = try await engine.fileStatistics()
      guard continued.matches(tail), continued.style.complete, continued.media.complete,
        ordered(continued.style.markdown) == expected(tail), afterTail.appendedPages > afterRepeat.appendedPages else {
        throw BoomError.invalid("Actual current-to-tail continuation was eager, incomplete or differs from the whole-source oracle.")
      }
      _ = try await engine.logicalMarkup(tail); _ = try await engine.logicalMarkup(head)
      let afterCached = try await engine.fileStatistics()
      guard afterCached.appendedPages == afterTail.appendedPages, afterCached.appendedBytes == afterTail.appendedBytes,
        afterCached.rootPublications == afterHead.rootPublications,
        engine.custodySnapshot.jobs == custody.jobs, engine.custodySnapshot.reservedPayloadBytes == custody.reservedPayloadBytes,
        session.isCurrent(read), session.generation == generation, session.arenaID == arena,
        try currentMixedView().sourceVersion == version, input.firstRefusal == nil, commands.firstFailure == nil else {
        throw BoomError.invalid("Derived demand queries changed the native source or leaked actual jobs/pages.")
      }
      try await requireDocumentInputSource(replacement, root: read.source)
      try await mixedResponder(false, event: 0, measured: false)
      try await requireDocumentInputSource(bytes, root: original)
      try await mixedCaret(0, event: 0, measured: false)
      visibleDemandVerified = true
    }

    // These are the original native source/range/clipboard/SDK-history
    // assertions, hosted in the existing signed App.run instead of XCTest's
    // unproved key-window lifecycle. They exercise no hardware input service.
    private func verifyCollapsedMediaClipboard(original: PagedNativeLogicalSnapshot, bytes: Data) async throws {
      guard let model = workspace, let input = model.pagedInput, let commands = model.pagedCommands,
        let session = model.pagedSession, let viewport = model.pagedViewport,
        let window, let documentID else {
        throw BoomError.stale("Collapsed-media verification lost its actual document graph.")
      }
      let image = NSImage(size: NSSize(width: 72, height: 42))
      image.lockFocus(); NSColor.systemRed.setFill(); NSRect(x: 0, y: 0, width: 72, height: 42).fill(); image.unlockFocus()
      guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:]) else {
        throw BoomError.invalid("The fixed public attachment could not be prepared.")
      }
      if normalMemory { recordGraphicsStage("clipboard-bitmap-prepared") }
      let chatVisible = model.state.showChat == true
      if model.selectedChat == nil { try model.newChat() }
      model.attachToCurrentChat([.bytes(name: "public-collapsed-verification.png", data: png)])
      try await model.joinWorkspaceOperation(); try await model.flush()
      guard !model.isBusy, model.errorMessage == nil,
        let record = model.state.attachments.last,
        record.name == "public-collapsed-verification.png",
        try model.store.vault.get(.attachment, id: record.id) == png else {
        throw BoomError.invalid("The real public attachment import did not join with its original bytes.")
      }
      if (model.state.showChat == true) != chatVisible { model.toggle("chat") }
      // Chat attachment setup may transfer focus. Acquire this real live
      // editor again; do not bypass currentMixedView's exact key/responder test.
      guard let live = input.activeView, viewport.textView === live, live.window === window,
        window.isKeyWindow, window.makeFirstResponder(live), window.firstResponder === live else {
        throw BoomError.unavailable("Collapsed-media verification could not receive its actual editor focus.")
      }
      _ = try currentMixedView()
      for marker in ["[asset][]", "![asset][]"] {
        let prefix = "Before e\u{301}🙂\n"
        let tail = "\nAfter\n\n[asset]: boom-attachment:\(record.id.uuidString)\n"
        let text = prefix + marker + tail, deleted = prefix + tail
        try await NativeCheckEvidence.replacePublicDocument(model, text: text, id: documentID, caret: 0)
        let view = try currentMixedView()
        await viewport.joinMarkup()
        guard viewport.markupFailure == nil else {
          throw BoomError.invalid("Collapsed-media verification did not join its actual source projection.")
        }
        view.setMedia(model: model); MarkdownStyle.apply(to: view)
        await view.inlineMedia.joinPendingLoads()
        let range = (text as NSString).range(of: marker)
        guard view.inlineMedia.lastFailure == nil, view.inlineMedia.currentRanges == [range] else {
          throw BoomError.invalid("Collapsed media did not project its entire accepted source marker.")
        }
        view.setSelectedRange(range, affinity: .upstream, stillSelecting: false)
        let beforeSelection = try input.currentDocumentSelection()
        let beforeSource = try session.captureLogicalState().source
        let board = NSPasteboard.general, sentinel = "retained-before-original-publication"
        board.clearContents()
        guard view.selectedRange() == range, board.setString(sentinel, forType: .string) else {
          throw BoomError.unavailable("Collapsed-media verification could not prepare its exact native selection/clipboard.")
        }
        view.cut(nil)
        guard Data(view.string.utf8) == Data(text.utf8),
          try session.captureLogicalState().source.isSame(beforeSource),
          board.string(forType: .string) == sentinel else {
          throw BoomError.invalid("Actual native Cut changed source/clipboard before original publication could join.")
        }
        // The production media join owns both preparation and publication,
        // including entered cancellation and publication-first source deletion.
        await view.inlineMedia.joinPendingLoads()
        try await commands.joinPendingCommand()
        guard view.inlineMedia.lastFailure == nil, Data(view.string.utf8) == Data(deleted.utf8),
          case .bytes(let name, let copied)? = AttachmentInput.read(board)?.first,
          name == record.name, copied == png,
          try model.store.vault.get(.attachment, id: record.id) == png else {
          throw BoomError.invalid("Actual collapsed Cut lost its full marker or byte-exact original clipboard representation.")
        }
        let cutSource = try session.captureLogicalState().source
        try await requireDocumentInputSource(Data(deleted.utf8), root: cutSource)
        try await mixedResponder(false, event: 0, measured: false)
        guard try input.currentDocumentSelection() == beforeSelection,
          window.firstResponder === input.activeView else {
          throw BoomError.invalid("Actual responder Undo did not restore the complete collapsed-marker selection.")
        }
        try await requireDocumentInputSource(Data(text.utf8), root: beforeSource)
        try await mixedResponder(true, event: 0, measured: false)
        try await requireDocumentInputSource(Data(deleted.utf8), root: cutSource)
        guard try model.store.vault.get(.attachment, id: record.id) == png,
          input.firstRefusal == nil, commands.firstFailure == nil else {
          throw BoomError.invalid("Native Cut/Undo/Redo changed the retained attachment or refused its actual source.")
        }
        try await mixedResponder(false, event: 0, measured: false) // undo Cut
        try await mixedResponder(false, event: 0, measured: false) // undo real fixture replacement
        try await requireDocumentInputSource(bytes, root: original)
        await viewport.joinMarkup(); await view.inlineMedia.joinPendingLoads()
      }
      NSPasteboard.general.clearContents()
      try await mixedCaret(0, event: 0, measured: false)
      collapsedMediaVerified = true
    }

    private func verifyMarkupAndMediaControls() async throws {
      guard plan.utf8Bytes == 72_196, NSApp.isRunning, NSApp.isActive,
        let session = workspace?.pagedSession else {
        throw BoomError.invalid("The short markup/media controls require their actual signed App.run source: bytes=\(plan.utf8Bytes), running=\(NSApp.isRunning), active=\(NSApp.isActive), session=\(workspace?.pagedSession != nil).")
      }
      let original = try session.captureLogicalState().source, bytes = try await documentInputBytes()
      guard UInt64(bytes.count) == plan.utf8Bytes else {
        throw BoomError.invalid("The markup/media controls lost their exact public baseline.")
      }
      do {
        markupVerificationStage = "visible-demand"
        if normalMemory { recordGraphicsStage("before-markup-verification") }
        try await verifyVisibleDemandMarkup(original: original, bytes: bytes)
        if normalMemory { recordGraphicsStage("after-markup-verification") }
        markupVerificationStage = "collapsed-media"
        try await verifyCollapsedMediaClipboard(original: original, bytes: bytes)
        if normalMemory { recordGraphicsStage("after-media-verification") }
        try await requireDocumentInputSource(bytes, root: original)
        _ = try currentMixedView()
        markupVerificationStage = "complete"
      } catch {
        var joined = await joinedDocumentInputFailure(error)
        if let viewport = workspace?.pagedViewport {
          await viewport.joinMarkup()
          if let failure = viewport.markupFailure { joined = DeveloperInputControlFailure(original: joined, cleanup: failure) }
        }
        if let view = workspace?.pagedInput?.activeView {
          await view.inlineMedia.joinPendingLoads()
          if let failure = view.inlineMedia.lastFailure { joined = DeveloperInputControlFailure(original: joined, cleanup: failure) }
        }
        throw joined // the existing Prepared shutdown retains any failed graph
      }
    }

    func verifyAfterCapture() async throws {
      vmAfter = currentVMCategories()
      try requireManagedSource()
      if plan.utf8Bytes == 72_196 && (plan.isMixed || normalMemory) {
        // The timing interval has ended. Reacquire actual readiness without
        // changing its captured source or selection before responder controls.
        try await receiveMixedReadiness(event: 0)
        try await verifyMarkupAndMediaControls()
      }
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
        do { try await workspace.shutdown(); backupOriginalClosed = true }
        catch { failures.append("Actual workspace close: " + error.localizedDescription) }
      }
      guard failures.isEmpty else { throw BoomError.unavailable(failures.joined(separator: "; ")) }
      window?.close() // do not detach a failed actual native/window receiver
      if liveBackupVerified { try await verifyColdBackupRestore() }
      shutdownJoined = true
    }

    /// Normal memory observation only. Successful shutdown has already joined
    /// the actual workspace and closed its windows; release this fixture's
    /// remaining strong references before taking the final graphics sample.
    func releaseNormalGraphForObservation() async {
      guard normalMemory, shutdownJoined else { return }
      recordGraphicsStage("closed-retained")
      weak var oldWorkspace = workspace
      weak var oldHost = host
      weak var oldWindow = window
      weak var oldEditor = managedEditor
      window?.contentView = nil
      managedEditor = nil; host = nil; window = nil; workspace = nil; bitmap = nil
      try? await Task.sleep(for: .seconds(1))
      releasedGraphOwners = ["workspace_deallocated": oldWorkspace == nil,
        "host_deallocated": oldHost == nil, "window_deallocated": oldWindow == nil,
        "editor_deallocated": oldEditor == nil]
      recordGraphicsStage("released-graph")
    }

    private func recordGraphicsStage(_ stage: String) {
      let vm = currentVMCategories()
      graphicsStages.append(["stage": stage, "available": vm["available"] ?? false,
        "uptime_seconds": ProcessInfo.processInfo.systemUptime,
        "physical_footprint_bytes": vm["physical_footprint_bytes"] ?? 0,
        "graphics_footprint_bytes": vm["graphics_footprint_bytes"] ?? 0,
        "resident_bytes": vm["resident_bytes"] ?? 0,
        "window_visible": window?.isVisible ?? false,
        "window_key": window?.isKeyWindow ?? false,
        "window_occlusion_visible": window?.occlusionState.contains(.visible) ?? false,
        "window_backing_scale": window?.backingScaleFactor ?? 0,
        "host_width": host?.frame.width ?? 0, "host_height": host?.frame.height ?? 0,
        "viewport_width": workspace?.pagedViewport?.frame.width ?? 0,
        "viewport_height": workspace?.pagedViewport?.frame.height ?? 0,
        "text_width": managedEditor?.frame.width ?? 0,
        "text_height": managedEditor?.frame.height ?? 0,
        "plain_text_height": ((host as? NSScrollView)?.documentView as? NSTextView)?.frame.height ?? 0])
    }

    private func observeGraphicsIdle(at point: String) async throws -> Bool {
      guard graphicsIdlePoint == point else { return false }
      if point == "primed" || point == "flattened-primed" {
        captureGraphicsLayerHierarchy()
      }
      if point == "editor-display" {
        host?.layoutSubtreeIfNeeded(); window?.displayIfNeeded(); CATransaction.flush()
        recordGraphicsStage("display-submitted")
      }
      for tick in 1...20 {
        try await Task.sleep(for: .milliseconds(100))
        recordGraphicsStage("idle-\(point)-\(tick)")
      }
      return true
    }

    private func captureGraphicsLayerHierarchy() {
      guard let viewport = workspace?.pagedViewport else { return }
      let views: [(String, NSView?)] = [
        ("window-content", window?.contentView), ("host", host),
        ("viewport", viewport), ("clip", viewport.contentView),
        ("text", viewport.textView),
      ]
      graphicsLayerHierarchy = views.compactMap { name, candidate in
        guard let view = candidate else { return nil }
        let backing = view.convertToBacking(view.bounds)
        return ["name": name, "class": String(describing: type(of: view)),
          "view": String(describing: Unmanaged.passUnretained(view).toOpaque()),
          "width": view.frame.width, "height": view.frame.height,
          "backing_width": backing.width, "backing_height": backing.height,
          "visible_width": view.visibleRect.width, "visible_height": view.visibleRect.height,
          "wants_layer": view.wantsLayer, "draws_subviews_into_layer": view.canDrawSubviewsIntoLayer,
          "layer": view.layer.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "none",
          "layer_class": view.layer.map { String(describing: type(of: $0)) } ?? "none",
          "layer_has_superlayer": view.layer?.superlayer != nil,
          "layer_contents_format": view.layer?.contentsFormat.rawValue ?? "none",
          "layer_draws_asynchronously": view.layer?.drawsAsynchronously ?? false,
          "layer_sublayer_formats": view.layer?.sublayers?.map { $0.contentsFormat.rawValue } ?? [],
          "layer_sublayer_classes": view.layer?.sublayers?.map { String(describing: type(of: $0)) } ?? [],
          "layer_sublayer_async": view.layer?.sublayers?.map { $0.drawsAsynchronously } ?? []] as [String: Any]
      }
    }

    func writeGraphicsIdleReceipt(failures: [String]) throws {
      let receipt: [String: Any] = ["schema": 1, "scope": "Diagnostic native editor preparation with a fixed idle interval; no held writer, scrolling, backup or model generation",
        "idle_point": graphicsIdlePoint ?? "none",
        "run_id": graphicsRunID.uuidString, "pid": ProcessInfo.processInfo.processIdentifier,
        "executable_path": CommandLine.arguments[0],
        "status": failures.isEmpty && shutdownJoined ? "complete" : "incomplete",
        "failures": failures, "graphics_lifecycle_stages": graphicsStages,
        "graphics_layer_hierarchy": graphicsLayerHierarchy,
        "released_graph_owners": releasedGraphOwners]
      try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        .write(to: root.appendingPathComponent("graphics-idle-receipt.json"), options: .withoutOverwriting)
    }

    /// Ordinary recipe files are capped at32 entries,16 directories/depth6,
    /// and the fixed byte ceiling. Caller-owned TMPDIR admission is separate;
    /// never inspect that shared directory during typing.
    private func diskExtent(reservingReceipt: Bool, forBackupPreparation: Bool = false,
      reservingWorkspaceCopies: Int = 0, reservingDirectories: Int = 0,
      copyingBackupSnapshot: Bool = false) throws -> UInt64 {
      // Only the fixed short backup setup/restore may hold three same-volume
      // workspace trees. Steady observations retain the original16-dir bound.
      let directoryLimit = forBackupPreparation && plan.utf8Bytes == 72_196 ? 20 : 16
      guard (0...2).contains(reservingWorkspaceCopies), (0...2).contains(reservingDirectories),
        forBackupPreparation || (reservingWorkspaceCopies == 0 && reservingDirectories == 0),
        !copyingBackupSnapshot || (forBackupPreparation && reservingWorkspaceCopies == 1 && reservingDirectories == 2) else {
        throw BoomError.invalid("Backup preparation reservation differs from its fixed phase.")
      }
      // Normal-memory TMPDIR is caller-owned shared infrastructure. Validate
      // it at admission, but never inventory its unrelated contents here.
      var pending: [(URL, Int)] = normalMemory ? [(root, 0)] : [(root, 0), (temporaryRoot, 0)]
      var files = 0, directories = 0, bytes: UInt64 = 0
      var workspaceFiles = 0, workspaceDirectories = 0, workspaceBytes: UInt64 = 0
      // Restore copies the captured snapshot, not the workspace that kept
      // receiving edits after that snapshot. Count its actual existing tree
      // in this same bounded traversal; all original caps remain unchanged.
      let workspaceRoot = root.appendingPathComponent(copyingBackupSnapshot ? "backup-controls/snapshot" : "workspace", isDirectory: true)
      while let (directory, depth) = pending.popLast() {
        guard depth < 6, directories < directoryLimit else {
          throw BoomError.budget("Public fixture directory bound exceeded.")
        }
        directories += 1
        if directory == workspaceRoot || directory.path.hasPrefix(workspaceRoot.path + "/") { workspaceDirectories += 1 }
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
            if child.path.hasPrefix(workspaceRoot.path + "/") {
              workspaceFiles += 1; workspaceBytes += UInt64(info.st_size)
            }
          default: throw BoomError.invalid("Public fixture contains a nonregular entry.")
          }
          guard files <= (reservingReceipt ? 31 : 32),
            bytes <= plan.diskLimit - (reservingReceipt ? 16_384 : 0) else {
            throw BoomError.budget("Public fixture disk bound exceeded.")
          }
        }
      }
      guard reservingWorkspaceCopies == 0 || workspaceDirectories > 0 else {
        throw BoomError.invalid("Backup reservation lost its actual copy source.")
      }
      let copiedBytes = workspaceBytes.multipliedReportingOverflow(by: UInt64(reservingWorkspaceCopies))
      let reservedBytes = bytes.addingReportingOverflow(copiedBytes.partialValue)
      guard !copiedBytes.overflow, !reservedBytes.overflow,
        files + workspaceFiles * reservingWorkspaceCopies <= (reservingReceipt ? 31 : 32),
        directories + workspaceDirectories * reservingWorkspaceCopies + reservingDirectories <= directoryLimit,
        reservedBytes.partialValue <= plan.diskLimit - (reservingReceipt ? 16_384 : 0) else {
        throw BoomError.budget("Actual workspace copies would exceed the fixed backup preparation disk envelope.")
      }
      return bytes
    }

    func writeReceipt(captureFinished: Bool, failures: [String]) throws {
      let extent: UInt64?
      let extentIssue: String?
      if failures.isEmpty {
        extent = try diskExtent(reservingReceipt: true, forBackupPreparation: backupPhaseActive)
        extentIssue = nil
      } else {
        do {
          extent = try diskExtent(reservingReceipt: true, forBackupPreparation: backupPhaseActive)
          extentIssue = nil
        } catch {
          // Keep the primary failed-run receipt even when a partial backup or
          // failed close leaves the strict success envelope unqualified.
          extent = nil
          extentIssue = error.localizedDescription
        }
      }
      let receipt: [String: Any] = [
        "schema": 1, "status": failures.isEmpty && (normalMemory || captureFinished) && shutdownJoined && sourceVerified
          && completed == plan.operations ? "complete" : "incomplete",
        "requested_cycles": plan.operations, "completed_cycles": completed,
        "operation_program": plan.isMixed ? "mixed-v2" : "head-paired-v1",
        "mixed_slots": plan.isMixed ? Self.mixedSlots : [],
        "mixed_warmed_before_donation": plan.isMixed && completedWarmSlots == 20,
        "mixed_warm_completed": completedWarmSlots, "warm_marked_states": warmMarkedStates,
        "mixed_warm_last_slot": lastWarmSlot.map { $0 as Any } ?? NSNull(),
        "startup_input_before": startupBefore ?? ["available": false],
        "startup_input_after": startupAfter ?? ["available": false],
        "startup_incidental_undo_attempted": startupUndoAttempted,
        "startup_incidental_undo_joined": startupUndoJoined,
        "startup_incidental_undo_groups": startupUndoGroups,
        "startup_imported_baseline": startupImportedState ?? ["available": false],
        "startup_history_before_recovery": startupHistoryState ?? ["available": false],
        "priming_before": primingBefore ?? ["available": false],
        "priming_after_insert": primingAfterInsert ?? ["available": false],
        "priming_after_delete": primingAfterDelete ?? ["available": false],
        "vm_categories_before_capture": vmBefore ?? ["available": false],
        "vm_categories_after_capture": vmAfter ?? ["available": false],
        "graphics_lifecycle_stages": graphicsStages,
        "released_graph_owners": releasedGraphOwners,
        "application_before_focus": applicationBeforeFocus ?? ["available": false],
        "application_after_focus": applicationAfterFocus ?? ["available": false],
        "reactivation_count": reactivationCount, "last_reactivation_event": lastReactivationEvent,
        "reactivation_gap_total_seconds": reactivationTotalSeconds,
        "reactivation_gap_maximum_seconds": reactivationMaximumSeconds,
        "reactivation_outside_operation_spans": true,
        "mixed_ready_includes_durability_join": false,
        "mixed_final_durability_export_outside_operation_spans": true,
        "synchronous_cpu_stage": "Editor.PublicInputDispatch",
        "ready_wait_stage": "Editor.PublicReadyWait",
        "end_to_ready_stage": "Editor.PublicMixedOperation",
        "offscreen_sdk_diagnostic": !(plan.isMixed || normalMemory), "normal_release_memory_observation": normalMemory,
        "bitmap_raster_exercised": !normalMemory,
        "post_capture_clipboard_bitmap_verification": normalMemory,
        "actual_held_writer_control_passed": heldWriterVerified,
        "actual_held_writer_shift_anchor_passed": heldScrollShiftVerified,
        "actual_visible_demand_markup_passed": visibleDemandVerified,
        "actual_collapsed_media_clipboard_passed": collapsedMediaVerified,
        "markup_media_verification_stage": markupVerificationStage,
        "markup_media_control_scope": "Public72K signed App.run only, outside measured operations; exact head/tail demand, cached-prefix held writer, original clipboard and responder Undo. No hardware input, predecessor-display ABA or input-method service acceptance. Cold dependent-prefix cancellation is a separate Engine/ABI component.",
        "held_writer_failure_state": heldWriterFailureState ?? ["available": false],
        "document_input_control_stage": documentInputStage,
        "actual_document_context_control_passed": documentContextVerified,
        "actual_adopting_final_control_passed": adoptingFinalVerified,
        "adopting_final_queued_at_focus_move": adoptingFinalQueuedAtFocus.map { $0 as Any } ?? NSNull(),
        "actual_tab_pointer_control_passed": tabPointerVerified,
        "actual_first_key_focus_custody_passed": firstKeyFocusVerified,
        "first_key_focus_custody_scope": "Actual native event and responder move in one App.run turn before async preparation; exact source/one Undo group. No entered-backend hold, hardware input or input-method-service acceptance.",
        "native_tab_oracles": nativeTabObservations,
        "document_input_control_scope": "Public72K App-run preparation only; actual Session/context/adoption/SDK Undo and programmatic native events. No hardware keyboard or input-method-service acceptance.",
        "actual_live_backup_control_passed": liveBackupVerified,
        "actual_backup_cancel_retry_control_passed": cancelledBackupVerified,
        "actual_backup_cold_restore_control_passed": backupColdRestoreVerified,
        "backup_control_stage": backupControlStage, "backup_preparation_directory_cap": 20,
        "backup_control_scope": "Public72K App-run only; live controls before measurement, cold restore after original shutdown. No GiB backup claim.",
        "slow_dispatch_threshold_ns": 8_000_000,
        "fixture_kind": plan.kind, "storage_route": "files",
        "primitive_replacements_per_cycle": plan.isMixed ? (NSNull() as Any) : (2 as Any), "public_utf8_bytes": plan.utf8Bytes,
        "physically_generated_bytes": generatedBytes, "generation_stream_chunk_limit": 64 << 10,
        "whole_source_sha256": expectedDigest?.map { String(format: "%02x", $0) }.joined() ?? "absent",
        "ordinary_import_joined": importJoined, "ordinary_selection_joined": selectionJoined,
        "preparation_export_joined": preparationExportJoined, "final_export_joined": finalExportJoined,
        "observation_deadline_seconds": normalMemory ? Self.normalObservationSeconds : Self.observationSeconds,
        "source_verified": sourceVerified, "capture_finish_acknowledged": captureFinished,
        "workspace_shutdown_joined": shutdownJoined,
        "process_footprint_before_bytes": footprintBefore, "process_footprint_after_bytes": footprintAfter,
        "process_peak_footprint_bytes": peakFootprint,
        "workspace_disk_bytes_before_receipt": extent.map { $0 as Any } ?? NSNull(),
        "workspace_disk_observation_error": extentIssue.map { $0 as Any } ?? NSNull(),
        "workspace_disk_limit_bytes": plan.diskLimit, "target_lifetime_seconds": plan.lifetimeSeconds, "failures": failures,
        "scope": normalMemory ? "Actual normal Release ordinary graph, physical streamed file and exact imports/exports, fixed paired native edits and synchronous layout with existing20ms memory Probe. The timed input loop performs no cached-view raster; post-loop verification encodes a 72x42 clipboard bitmap while sampling continues. No Mach suspension/model/GPU or presentation latency claim." : plan.isMixed ? "Warmed actual ordinary graph with bounded head/middle/tail edits, NFD/ZWJ deletion, direct marked-text primitives, actual window-responder Undo/Redo, bounded and whole-source root edits, read-only scroll/click/recenter and interleaved contained input. Visible actual App/key window with SDK raster; no hardware keyboard/input-method service/compositor, model or GPU-overlap acceptance. CPU dispatch spans contain no await; command/read/source joins have separate wait spans inside end-to-ready. All raw observations and failures retained." : "Warmed actual ordinary file WorkspaceModel/WorkspaceView/managed viewport; physical public ASCII imported/export-verified in <=64KiB chunks. Direct paired native edits, synchronous host layout and completed SDK cached-bitmap raster, closed-loop100ms pacing. No inference, IME, hardware input dispatch, deferred draw/compositor acceptance, or per-cycle whole-source copies/hash/files/Mach samples."
      ]
      let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
      guard bytes.count <= 16_384 else { throw BoomError.budget("Public fixture receipt exceeds its bound.") }
      try bytes.write(to: root.appendingPathComponent("fixture-receipt.json"), options: .withoutOverwriting)
      if failures.isEmpty { _ = try diskExtent(reservingReceipt: false) }
    }
  }
}
