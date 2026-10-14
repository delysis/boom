import AppKit
import Combine
import BoomCore
import Foundation
import SwiftUI
import XCTest
@testable import Boom

private struct BoundedWorkspaceCleanupFailure: Error, LocalizedError {
  let original: Error
  let cleanup: Error
  var errorDescription: String? {
    "\(original.localizedDescription) Cleanup also failed: \(cleanup.localizedDescription)"
  }
}

/// Holds only after a real cloned pages file has written its first 64 KiB.
/// The deadline is cleanup protection, never evidence that work completed.
private final class LiveBackupCopyHold: @unchecked Sendable {
  let entered: XCTestExpectation
  private let documentName: String
  private let releaseSignal = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var observation: (source: URL, staged: URL, bytes: UInt64)?
  private var held = false
  private var expired = false
  init(documentID: UUID, entered: XCTestExpectation) {
    documentName = documentID.uuidString.lowercased(); self.entered = entered
  }
  func copied(_ source: URL, _ staged: URL, _ bytes: UInt64) throws {
    guard source.lastPathComponent == "pages",
      source.deletingLastPathComponent().lastPathComponent == documentName, bytes >= 65_536 else { return }
    lock.lock()
    guard observation == nil else { lock.unlock(); return }
    observation = (source, staged, bytes); held = true
    lock.unlock(); entered.fulfill()
    let timedOut = releaseSignal.wait(timeout: .now() + .seconds(10)) != .success
    lock.lock(); held = false; expired = timedOut; lock.unlock()
    if timedOut { throw BoomError.unavailable("The actual backup copy missed its ten-second release deadline.") }
  }
  func release() { releaseSignal.signal() }
  var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }
  var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return expired }
  var actualFiles: (source: URL, staged: URL, bytes: UInt64)? {
    lock.lock(); defer { lock.unlock() }; return observation
  }
}

/// Source-authored ordinary Model/WorkspaceView controls. No fake engine,
/// WorkspaceState, durable ACK, native history or actor callback is supplied.
@MainActor final class BoundedWorkspaceConsumerTests: XCTestCase {
  @MainActor private final class CharacterUndoObservation: NSObject, NSTextStorageDelegate {
    weak var view: PagedNativeTextView?
    private(set) var characterNotifications = 0
    private(set) var exposedManagerDuringCharacters = false
    init(view: PagedNativeTextView) { self.view = view }
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
      range editedRange: NSRange, changeInLength delta: Int) {
      if editedMask.contains(.editedCharacters) {
        characterNotifications += 1
        exposedManagerDuringCharacters = exposedManagerDuringCharacters || view?.undoManager != nil
      }
    }
  }
  private static var failedModel: WorkspaceModel?
  private static var failedWindow: NSWindow?
  private static var failedRoot: URL?
  private static var failedExport: URL?
  private func root(parent: URL? = nil) throws -> URL {
    let result = (parent ?? FileManager.default.temporaryDirectory).appendingPathComponent("Bloom-bounded-consumer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
    Self.failedRoot = result; return result
  }
  private func diagnosticRoot() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["TMPDIR"], !path.isEmpty, path.hasPrefix("/") else {
      throw BoomError.invalid("The public native diagnostic requires its actual absolute caller TMPDIR.")
    }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
      throw BoomError.invalid("The public native diagnostic TMPDIR is not an existing directory.")
    }
    return try root(parent: URL(fileURLWithPath: path, isDirectory: true))
  }
  private func open(_ root: URL, requiresActualKeyWindow: Bool = true) async throws -> WorkspaceModel {
    try PagedNativeFixtureApplication.bootstrap()
    let store = try await Task.detached { try WorkspaceStore(rootOverride: root) }.value
    let model: WorkspaceModel
    do { model = try await WorkspaceModel(storeOverride: store, loadModels: false) }
    catch let failure as WorkspacePagedStartupFailure { Self.failedModel = failure.model; throw failure.original }
    Self.failedModel = model
    XCTAssertTrue(model.layout.isAuthor, "This exact control requires the actual Author product layout.")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 780),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
    Self.failedWindow = window
    try await focusCurrentEditor(model, requiresActualKeyWindow: requiresActualKeyWindow)
    return model
  }
  private func focusCurrentEditor(_ model: WorkspaceModel, requiresActualKeyWindow: Bool = true) async throws {
    try Task.checkCancellation()
    let window = try XCTUnwrap(Self.failedWindow)
    window.contentView?.layoutSubtreeIfNeeded()
    let becameKey = !requiresActualKeyWindow || window.isKeyWindow ? nil : XCTNSNotificationExpectation(
      name: NSWindow.didBecomeKeyNotification, object: window)
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    if let becameKey {
      guard await XCTWaiter.fulfillment(of: [becameKey], timeout: 10) == .completed else {
        throw BoomError.unavailable("The ordinary editor did not receive its actual key-window notification.")
      }
    }
    try Task.checkCancellation()
    let view = try XCTUnwrap(model.pagedInput?.activeView)
    guard model.pagedViewport?.textView === view, view.window === window,
      (!requiresActualKeyWindow || window.isKeyWindow), window.makeFirstResponder(view), window.firstResponder === view else {
      throw BoomError.unavailable("The ordinary editor did not acquire native focus: mounted=\(view.window === window), currentViewport=\(model.pagedViewport?.textView === view), keyWindow=\(window.isKeyWindow), firstResponder=\(window.firstResponder === view).")
    }
  }
  private func joinedClose(_ model: WorkspaceModel) async throws {
    try await model.joinWorkspaceOperation()
    try await model.shutdown()
    Self.failedWindow?.orderOut(nil); Self.failedWindow?.close(); Self.failedWindow = nil
    Self.failedModel = nil
  }
  private func removeJoinedScratch(_ root: URL) async throws {
    guard Self.failedModel == nil, Self.failedWindow == nil else { throw BoomError.stale("Actual ordinary source owners did not join.") }
    let exported = Self.failedExport
    try await Task.detached {
      if let exported, FileManager.default.fileExists(atPath: exported.path) { try FileManager.default.removeItem(at: exported) }
      try FileManager.default.removeItem(at: root)
    }.value
    Self.failedRoot = nil; Self.failedExport = nil
  }
  private func readSmallExport(_ url: URL) async throws -> Data {
    try await Task.detached {
      let file = try FileHandle(forReadingFrom: url)
      var closeAttempted = false
      do {
        var bytes = Data()
        while let part = try file.read(upToCount: 64), !part.isEmpty {
          guard bytes.count <= 4_096 - part.count else { throw BoomError.budget("The public small-export fixture exceeded its bounded read oracle.") }
          bytes.append(part)
        }
        closeAttempted = true; try file.close()
        return bytes
      } catch {
        let original = error
        if !closeAttempted {
          closeAttempted = true
          do { try file.close() } catch { throw BoundedWorkspaceCleanupFailure(original: original, cleanup: error) }
        }
        throw original
      }
    }.value
  }
  private func chatTextView(in view: NSView) -> ChatTextView? {
    if let text = view as? ChatTextView { return text }
    for child in view.subviews { if let text = chatTextView(in: child) { return text } }
    return nil
  }
  private func writeSource(_ root: URL, edgeText: String? = nil) async throws -> URL {
    guard (edgeText?.utf8.count ?? 0) <= 64 else { throw BoomError.budget("The public edge fixture exceeds its bound.") }
    let edge = edgeText.map { Data($0.utf8) }
    return try await Task.detached {
      let url = root.appendingPathComponent("public-source.md")
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw BoomError.unavailable("Could not create the physical public source.") }
      let file = try FileHandle(forWritingTo: url)
      let block = Data((0..<8_192).map { $0 % 128 == 127 ? UInt8(10) : UInt8(97) })
      do {
        for index in 0..<384 { // actual3MiB base; no3MiB String/Data
          if index == 1, let edge {
            var boundary = block
            boundary.replaceSubrange(8190..<8192, with: edge)
            try file.write(contentsOf: boundary)
          } else { try file.write(contentsOf: block) }
        }
        try file.synchronize(); try file.close()
      } catch { try? file.close(); throw error }
      return url
    }.value
  }

  private func sourceBytes(_ model: WorkspaceModel, atUTF16 offset: UInt64) async throws -> Data {
    let record = try XCTUnwrap(model.pagedSelectedRecord)
    let engine = try XCTUnwrap(model.pagedEngine)
    let start = try await engine.byteAtUTF16(record.document.revision, offset: offset)
    let output = try await engine.windowRetaining(record.document.revision, byteStart: start, maximumBytes: 64)
    let bytes = Data(output.value.text.utf8)
    try await engine.abandonJoinedRootOutput(output.lease)
    return bytes
  }

  func testActualWindowKeyInputKeepsTextKitCoalescingOutsideCanonicalUndoAndRedo() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try root(), model = try await open(scratch)
    let original = try XCTUnwrap(model.pagedSelectedRecord)
    let captured = try await model.captureDocument(original.document.id)
    let before = try XCTUnwrap(captured.completeSnapshot).text
    try await focusCurrentEditor(model)
    let commands = try XCTUnwrap(model.pagedCommands)
    let view = try XCTUnwrap(model.pagedInput?.activeView)
    let window = try XCTUnwrap(Self.failedWindow)
    XCTAssertEqual(Data(view.string.utf8), Data(before.utf8))
    XCTAssertFalse(view.allowsUndo); XCTAssertFalse(commands.manager.groupsByEvent)
    XCTAssertTrue(view.undoManager === commands.manager)
    XCTAssertEqual(commands.manager.groupingLevel, 0); XCTAssertFalse(commands.manager.canUndo)
    view.setSelectedRange(NSRange(location: before.utf16.count, length: 0))
    let observation = CharacterUndoObservation(view: view)
    let storage = view.boundedStorage, previousDelegate = storage.delegate
    storage.delegate = observation
    defer { storage.delegate = previousDelegate }
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    // The original failure came through this window→input-context→TextKit
    // path, before the native source primitive could mutate any characters.
    window.sendEvent(event)
    XCTAssertGreaterThan(observation.characterNotifications, 0)
    XCTAssertFalse(observation.exposedManagerDuringCharacters)
    XCTAssertNil(view.inputBinding?.firstRefusal); XCTAssertNil(storage.mutationFailure)
    XCTAssertTrue(view.undoManager === commands.manager)
    try await commands.joinPendingCommand(); try await model.flush()
    let edited = try await model.captureDocument(original.document.id)
    XCTAssertEqual(edited.completeSnapshot?.text, before + "a")
    XCTAssertEqual(try model.pagedCommands?.captureLogicalHistory().undo.count, 1)
    XCTAssertEqual(commands.manager.groupingLevel, 0)
    let entryKey = UndoManager.UserInfoKey(rawValue: "bloom.paged.native-entry.v1")
    XCTAssertNotNil(commands.manager.undoActionUserInfoValue(forKey: entryKey) as? NSObject)
    let responderManager = try XCTUnwrap(model.pagedInput?.activeView?.undoManager)
    XCTAssertTrue(responderManager === commands.manager)
    responderManager.undo(); try await commands.joinPendingCommand(); try await model.flush()
    let undone = try await model.captureDocument(original.document.id)
    XCTAssertEqual(undone.completeSnapshot?.text, before)
    XCTAssertFalse(commands.manager.canUndo); XCTAssertTrue(commands.manager.canRedo)
    responderManager.redo(); try await commands.joinPendingCommand(); try await model.flush()
    let redone = try await model.captureDocument(original.document.id)
    XCTAssertEqual(redone.completeSnapshot?.text, before + "a")
    XCTAssertFalse(commands.manager.canRedo); XCTAssertEqual(commands.manager.groupingLevel, 0)
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Actual window key/coalescing assertions failed; source and native owner retained.")
    }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }

  func testActualResponderUndoAndRedoActionsRestoreCanonicalSourceAndSelection() async throws {
    let failures = testRun?.failureCount ?? 0
    // This SDK action control requires a real mounted first responder. The
    // Application.run keyboard/menu journey separately requires a key window.
    let scratch = try diagnosticRoot(), model = try await open(scratch, requiresActualKeyWindow: false)
    let original = try XCTUnwrap(model.pagedSelectedRecord)
    let input = try XCTUnwrap(model.pagedInput), commands = try XCTUnwrap(model.pagedCommands)
    let view = try XCTUnwrap(input.activeView), window = try XCTUnwrap(Self.failedWindow)
    let beforeSelection = try input.currentDocumentSelection()
    XCTAssertEqual(view.string, ""); XCTAssertFalse(view.allowsUndo)
    XCTAssertTrue(window.firstResponder === view); XCTAssertTrue(view.undoManager === commands.manager)
    view.insertText("é🙂", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await commands.joinPendingCommand(); try await model.flush()
    let edited = try XCTUnwrap(model.pagedSelectedRecord)
    let editedCapture = try await model.captureDocument(original.document.id)
    let editedSelection = try input.currentDocumentSelection()
    XCTAssertEqual(editedCapture.completeSnapshot?.text, "é🙂")
    XCTAssertEqual(editedSelection.utf16Offset, 3); XCTAssertEqual(editedSelection.utf16Length, 0)
    XCTAssertEqual(try model.pagedCommands?.captureLogicalHistory().undo.count, 1)

    let oldBinding = try XCTUnwrap(view.inputBinding), oldStorage = view.boundedStorage
    let oldContext = try XCTUnwrap(view.inputContext), oldClient = try XCTUnwrap(oldContext.client as? PagedNativeTextInputClient)
    let oldManager = try XCTUnwrap(view.layoutManager), oldContainer = try XCTUnwrap(view.textContainer)
    let undoAction = NSSelectorFromString("undo:"), redoAction = NSSelectorFromString("redo:")
    let undoItem = NSMenuItem(title: "Undo", action: undoAction, keyEquivalent: "z")
    let redoItem = NSMenuItem(title: "Redo", action: redoAction, keyEquivalent: "z")
    redoItem.keyEquivalentModifierMask = [.command, .shift]
    XCTAssertNil(undoItem.target); XCTAssertNil(redoItem.target)
    XCTAssertTrue(view.validateUserInterfaceItem(undoItem)); XCTAssertFalse(view.validateUserInterfaceItem(redoItem))
    // Start with the actual responder chain, not UndoManager.undo().
    XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(undoAction, with: undoItem))
    try await commands.joinPendingCommand(); try await model.flush()
    let undoneCapture = try await model.captureDocument(original.document.id)
    let current = try XCTUnwrap(input.activeView)
    XCTAssertEqual(undoneCapture.completeSnapshot?.text, "")
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, original.document.revision)
    XCTAssertEqual(try input.currentDocumentSelection(), beforeSelection)
    XCTAssertTrue(current === view); XCTAssertEqual(oldBinding.state, .retired)
    XCTAssertFalse(current.boundedStorage === oldStorage); XCTAssertTrue(oldStorage.layoutManagers.isEmpty)
    XCTAssertTrue(current.layoutManager === oldManager); XCTAssertTrue(current.textContainer === oldContainer)
    XCTAssertTrue(current.inputContext === oldContext); XCTAssertFalse(oldClient.isRetired)
    XCTAssertTrue(window.firstResponder === current)
    XCTAssertFalse(current.validateUserInterfaceItem(undoItem)); XCTAssertTrue(current.validateUserInterfaceItem(redoItem))

    // The view and document context stay current; old storage/binding are inert.
    let stableRecord = model.pagedSelectedRecord, stableGeneration = model.pagedSession?.generation
    XCTAssertTrue(view.validateUserInterfaceItem(redoItem))
    oldStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "OLD")
    try await commands.joinPendingCommand()
    XCTAssertEqual(model.pagedSelectedRecord, stableRecord); XCTAssertEqual(model.pagedSession?.generation, stableGeneration)
    XCTAssertEqual(try input.currentDocumentSelection(), beforeSelection)
    XCTAssertTrue(commands.manager.canRedo)

    // Exercise the public SDK action dispatcher on that same actual responder.
    // Resolving a nil target through the application's key window is a separate
    // packaged route; this call deliberately nominates the observed responder.
    XCTAssertTrue(NSApp.sendAction(redoAction, to: try XCTUnwrap(window.firstResponder), from: redoItem))
    try await commands.joinPendingCommand(); try await model.flush()
    let redoneCapture = try await model.captureDocument(original.document.id)
    let redoneView = try XCTUnwrap(input.activeView)
    XCTAssertEqual(redoneCapture.completeSnapshot?.text, "é🙂")
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, edited.document.revision)
    XCTAssertEqual(try input.currentDocumentSelection(), editedSelection)
    XCTAssertTrue(window.firstResponder === redoneView); XCTAssertTrue(redoneView.undoManager === commands.manager)
    XCTAssertTrue(redoneView.validateUserInterfaceItem(undoItem)); XCTAssertFalse(redoneView.validateUserInterfaceItem(redoItem))
    XCTAssertFalse(redoneView.allowsUndo); XCTAssertEqual(commands.manager.groupingLevel, 0)
    XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure); XCTAssertNil(redoneView.boundedStorage.mutationFailure)
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Actual responder action assertions failed; source and native owners retained.")
    }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }

  func testActualContainedSelectedDeletionIsImmediateAndCanonicalUndoRestoresNativeSelection() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try diagnosticRoot(), model = try await open(scratch, requiresActualKeyWindow: false)
    let input = try XCTUnwrap(model.pagedInput), commands = try XCTUnwrap(model.pagedCommands)
    let session = try XCTUnwrap(model.pagedSession), window = try XCTUnwrap(Self.failedWindow)
    let initial = try XCTUnwrap(model.pagedSelectedRecord)
    try XCTUnwrap(input.activeView).insertText("é🙂x", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await commands.joinPendingCommand(); try await model.flush()
    let original = try XCTUnwrap(model.pagedSelectedRecord)
    let selector = NSSelectorFromString("deleteBackward:")
    for length in [3, 4] { // selected prefix, then the entire actual short source island
      let view = try XCTUnwrap(input.activeView)
      XCTAssertTrue(window.firstResponder === view); XCTAssertEqual(view.string, "é🙂x")
      view.setSelectedRange(NSRange(location: 0, length: 0)) // a real independently observed anchor
      view.setSelectedRange(NSRange(location: 0, length: length), affinity: .upstream, stillSelecting: false)
      let selected = try input.currentDocumentSelection()
      XCTAssertEqual(selected.utf16Offset, 0); XCTAssertEqual(selected.utf16Length, UInt64(length))
      XCTAssertTrue(selected.focusAtEnd); XCTAssertEqual(selected.affinity, .upstream)
      XCTAssertFalse(input.handlesDocumentCommand(selector))
      let generation = session.generation
      view.doCommand(by: selector)
      let expected = length == 3 ? "x" : ""
      XCTAssertEqual(session.generation, generation + 1)
      XCTAssertEqual(view.string, expected, "Contained selected deletion must finish before any worker publication await.")
      XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
      let deletionSelection = try input.currentDocumentSelection()
      try await commands.joinPendingCommand(); try await model.flush()
      let deleted = try await model.captureDocument(initial.document.id)
      XCTAssertEqual(deleted.completeSnapshot?.text, expected)
      XCTAssertEqual(model.pagedSelectedRecord?.document.revision.summary.bytes, UInt64(expected.utf8.count))
      XCTAssertEqual(model.pagedSelectedRecord?.document.revision.summary.utf16, UInt64(expected.utf16.count))
      XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(NSSelectorFromString("undo:"), with: nil))
      try await commands.joinPendingCommand(); try await model.flush()
      let undone = try await model.captureDocument(initial.document.id)
      XCTAssertEqual(undone.completeSnapshot?.text, "é🙂x")
      XCTAssertEqual(model.pagedSelectedRecord?.document.revision, original.document.revision)
      XCTAssertEqual(try input.currentDocumentSelection(), selected)
      XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(NSSelectorFromString("redo:"), with: nil))
      try await commands.joinPendingCommand(); try await model.flush()
      let redone = try await model.captureDocument(initial.document.id)
      XCTAssertEqual(redone.completeSnapshot?.text, expected)
      XCTAssertEqual(try input.currentDocumentSelection(), deletionSelection)
      XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(NSSelectorFromString("undo:"), with: nil))
      try await commands.joinPendingCommand(); try await model.flush()
      XCTAssertEqual(model.pagedSelectedRecord?.document.revision, original.document.revision)
    }
    XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Actual contained deletion assertions failed; source and native owners retained.")
    }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }

  func testActualOrdinaryLargeImportTailTypingUndoRedoAndColdHydrationPreserveExactRootsAndDraft() async throws {
    let failureCount = testRun?.failureCount ?? 0
    let scratch = try root(), model = try await open(scratch)
    let source = try await writeSource(scratch)
    try await model.importDocuments([source], flag: CancellationFlag())
    let imported = try XCTUnwrap(model.pagedSelectedRecord)
    XCTAssertEqual(imported.document.revision.summary.bytes, 3_145_728)
    XCTAssertNil(model.selectedDocument, "The real paged source is never a DocumentSnapshot/viewport substitution.")
    try await focusCurrentEditor(model)
    let viewport = try XCTUnwrap(model.pagedViewport)
    try viewport.requestScroll(toUTF16: imported.document.revision.summary.utf16 - 16)
    try await viewport.joinPresentation()
    let tail = try XCTUnwrap(viewport.visibleScrollWindow)
    XCTAssertEqual(tail.snapshot.sourceRevision, imported.document.revision)
    let logicalSource = try XCTUnwrap(model.pagedSession).captureLogicalRead().source
    XCTAssertTrue(tail.snapshot.isSame(logicalSource))
    XCTAssertLessThanOrEqual(tail.text.utf8.count, 16_384)
    try viewport.selectVisibleUTF16(0)
    let commands = try XCTUnwrap(model.pagedCommands)
    try await commands.joinPendingCommand()
    let clicked = try XCTUnwrap(model.pagedInput).currentDocumentSelection()
    try viewport.requestScroll(toUTF16: imported.document.revision.summary.utf16 - 16)
    try await viewport.joinPresentation()
    let extensionWindow = try XCTUnwrap(viewport.visibleScrollWindow)
    XCTAssertEqual(extensionWindow.start.utf16, clicked.utf16Offset)
    try viewport.selectVisibleUTF16(3, extending: true)
    try await commands.joinPendingCommand()
    let extended = try XCTUnwrap(model.pagedInput).currentDocumentSelection()
    XCTAssertEqual(extended.utf16Offset, clicked.utf16Offset); XCTAssertEqual(extended.utf16Length, 3)
    XCTAssertTrue(extended.focusAtEnd)
    try XCTUnwrap(model.pagedInput?.activeView).cut(nil)
    try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "aaa")
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision.summary.bytes, imported.document.revision.summary.bytes - 3)
    commands.manager.undo(); try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, imported.document.revision)
    XCTAssertEqual(try XCTUnwrap(model.pagedInput).currentDocumentSelection(), extended)
    let view = try XCTUnwrap(model.pagedInput?.activeView)
    view.setSelectedRange(NSRange(location: view.selectedRange().location, length: 0))
    let beforeCaret = view.selectedRange()
    view.insertText("Q", replacementRange: beforeCaret)
    try await model.flush()
    let edited = try XCTUnwrap(model.pagedSelectedRecord)
    XCTAssertEqual(edited.document.revision.summary.bytes, imported.document.revision.summary.bytes + 1)
    XCTAssertNotEqual(edited.document.revision, imported.document.revision)
    commands.manager.undo(); try await commands.joinPendingCommand()
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, imported.document.revision)
    XCTAssertTrue(commands.manager.canRedo)
    model.draft = "A retained owner draft."
    try await model.flush()
    let beforeReopen = try XCTUnwrap(model.pagedSelectedRecord)
    guard (testRun?.failureCount ?? 0) == failureCount else { throw BoomError.invalid("Actual first-owner assertions failed; source/evidence retained.") }
    try await joinedClose(model)
    let reopened = try await open(scratch)
    XCTAssertEqual(reopened.pagedSelectedRecord, beforeReopen)
    XCTAssertEqual(reopened.draft, "A retained owner draft.")
    let restored = try XCTUnwrap(reopened.pagedCommands)
    XCTAssertTrue(restored.manager.canRedo, "Actual Foundation Redo hydrates from the authenticated retained history.")
    restored.manager.redo(); try await restored.joinPendingCommand()
    XCTAssertEqual(reopened.pagedSelectedRecord?.document.revision, edited.document.revision)
    XCTAssertEqual(reopened.pagedInput?.activeView?.selectedRange().location, beforeCaret.location + 1)
    guard (testRun?.failureCount ?? 0) == failureCount else { throw BoomError.invalid("Actual ordinary assertions failed; owner/evidence retained.") }
    try await joinedClose(reopened); try await removeJoinedScratch(scratch)
  }

  func testActualLargeSelectAllReplaceDeleteUndoRedoPreserveGlobalSelectionWithoutLoadingWholeText() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try root()
    var model = try await open(scratch)
    let source = try await writeSource(scratch)
    try await model.importDocuments([source], flag: CancellationFlag())
    try await focusCurrentEditor(model)
    let original = try XCTUnwrap(model.pagedSelectedRecord)
    var commands = try XCTUnwrap(model.pagedCommands)
    let length = original.document.revision.summary.utf16
    _ = try await commands.navigate(toUTF16: length - 16,
      selectingUTF16: PagedNativeNavigationSelection(utf16Offset: length - 16, utf16Length: 0))
    try await focusCurrentEditor(model)
    let tail = try XCTUnwrap(model.pagedInput?.activeView)
    XCTAssertLessThanOrEqual(tail.string.utf8.count, PagedWorkingWindow.hardBytes)
    let input = try XCTUnwrap(model.pagedInput)
    let localCaret = tail.selectedRange().location
    // The native setters supply a normalized range. An already owned caret
    // is its actual anchor when extension keeps that endpoint fixed.
    tail.setSelectedRange(NSRange(location: localCaret, length: 3), affinity: .upstream, stillSelecting: true)
    let forward = try input.currentDocumentSelection()
    XCTAssertEqual(forward.utf16Offset, length - 16); XCTAssertEqual(forward.utf16Length, 3)
    XCTAssertTrue(forward.focusAtEnd); XCTAssertEqual(forward.affinity, .upstream)
    tail.setSelectedRange(NSRange(location: localCaret + 3, length: 0), affinity: .upstream, stillSelecting: false)
    tail.setSelectedRange(NSRange(location: localCaret, length: 3), affinity: .downstream, stillSelecting: true)
    let backward = try input.currentDocumentSelection()
    XCTAssertEqual(backward.utf16Offset, length - 16); XCTAssertEqual(backward.utf16Length, 3)
    XCTAssertFalse(backward.focusAtEnd); XCTAssertEqual(backward.affinity, .downstream)
    tail.selectAll(nil)
    let all = try input.currentDocumentSelection()
    XCTAssertEqual(all.utf16Offset, 0)
    XCTAssertEqual(all.utf16Length, length, "The direct menu action selects the entire file, not its mounted tail.")
    tail.doCommand(by: NSSelectorFromString("moveForward:"))
    try await commands.joinPendingCommand()
    let collapsedEnd = try XCTUnwrap(model.pagedInput).currentDocumentSelection()
    XCTAssertEqual(collapsedEnd.utf16Offset, length); XCTAssertEqual(collapsedEnd.utf16Length, 0)
    let endView = try XCTUnwrap(model.pagedInput?.activeView)
    endView.selectAll(nil); endView.doCommand(by: NSSelectorFromString("moveBackward:"))
    try await commands.joinPendingCommand()
    let collapsedStart = try XCTUnwrap(model.pagedInput).currentDocumentSelection()
    XCTAssertEqual(collapsedStart.utf16Offset, 0); XCTAssertEqual(collapsedStart.utf16Length, 0)
    // Logical direction and visual affinity are independent owned facts.
    // Undo must not turn the upstream visual preference into a start focus.
    try XCTUnwrap(model.pagedInput).setDocumentSelection(PagedNativeNavigationSelection(
      utf16Offset: 0, utf16Length: length, focusAtEnd: true, affinity: .upstream))
    let selected = try XCTUnwrap(model.pagedInput).currentDocumentSelection()
    XCTAssertEqual(selected.utf16Offset, 0); XCTAssertEqual(selected.utf16Length, length)
    XCTAssertTrue(selected.focusAtEnd); XCTAssertEqual(selected.affinity, .upstream)
    let selectionOwner = try XCTUnwrap(model.pagedInput)
    let beforeLogicalChange = try selectionOwner.observeSelection()
    let startFocused = PagedNativeNavigationSelection(utf16Offset: 0, utf16Length: length,
      focusAtEnd: false, affinity: .upstream)
    try selectionOwner.setDocumentSelection(startFocused)
    let afterLogicalChange = try selectionOwner.observeSelection()
    XCTAssertEqual(afterLogicalChange.range, beforeLogicalChange.range)
    XCTAssertEqual(afterLogicalChange.affinity, beforeLogicalChange.affinity)
    XCTAssertEqual(afterLogicalChange.selectionEpoch, beforeLogicalChange.selectionEpoch + 1)
    try selectionOwner.setDocumentSelection(startFocused)
    XCTAssertEqual(try selectionOwner.observeSelection(), afterLogicalChange)
    try selectionOwner.setDocumentSelection(selected)
    let replacement = "Café 🙂\nA small replacement."
    try XCTUnwrap(model.pagedInput?.activeView).insertText(replacement, replacementRange: NSRange(location: NSNotFound, length: 0))
    try await commands.joinPendingCommand(); try await model.flush()
    let replaced = try await model.captureDocument(original.document.id)
    XCTAssertEqual(replaced.completeSnapshot?.text, replacement)
    commands.manager.undo(); try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, original.document.revision)
    let restoredSelection = try XCTUnwrap(model.pagedInput).currentDocumentSelection()
    XCTAssertEqual(restoredSelection.utf16Offset, 0); XCTAssertEqual(restoredSelection.utf16Length, length)
    XCTAssertTrue(restoredSelection.focusAtEnd); XCTAssertEqual(restoredSelection.affinity, .upstream)
    XCTAssertEqual(model.pagedInput?.activeView?.selectionAffinity, .upstream)
    let focused = try XCTUnwrap(model.pagedSession).documentCoordinates()
    XCTAssertEqual(focused.utf16Start + UInt64(focused.localUTF16), length)
    XCTAssertLessThanOrEqual(try XCTUnwrap(model.pagedInput?.activeView).string.utf8.count, PagedWorkingWindow.hardBytes)
    try await model.flush(); try await joinedClose(model)
    model = try await open(scratch); commands = try XCTUnwrap(model.pagedCommands)
    let reopenedSelection = try XCTUnwrap(model.pagedInput).currentDocumentSelection()
    XCTAssertEqual(reopenedSelection, restoredSelection)
    XCTAssertEqual(model.pagedInput?.activeView?.selectionAffinity, .upstream)
    let reopenedFocus = try XCTUnwrap(model.pagedSession).documentCoordinates()
    XCTAssertEqual(reopenedFocus.utf16Start + UInt64(reopenedFocus.localUTF16), length)
    commands.manager.redo(); try await commands.joinPendingCommand(); try await model.flush()
    let redoSelection = try XCTUnwrap(model.pagedInput).currentDocumentSelection()
    XCTAssertEqual(redoSelection.utf16Offset, UInt64(replacement.utf16.count)); XCTAssertEqual(redoSelection.utf16Length, 0)
    XCTAssertFalse(redoSelection.focusAtEnd); XCTAssertEqual(redoSelection.affinity, .downstream)
    let current = try XCTUnwrap(model.pagedInput?.activeView)
    current.selectAll(nil); current.deleteBackward(nil)
    try await commands.joinPendingCommand(); try await model.flush()
    let deleted = try await model.captureDocument(original.document.id)
    XCTAssertEqual(deleted.completeSnapshot?.text, "")
    commands.manager.undo(); try await commands.joinPendingCommand(); try await model.flush()
    let restored = try await model.captureDocument(original.document.id)
    XCTAssertEqual(restored.completeSnapshot?.text, replacement)
    let deletionSelection = try XCTUnwrap(model.pagedInput).currentDocumentSelection()
    XCTAssertEqual(deletionSelection.utf16Offset, 0)
    XCTAssertEqual(deletionSelection.utf16Length, UInt64(replacement.utf16.count))
    commands.manager.redo(); try await commands.joinPendingCommand(); try await model.flush()
    let deletedAgain = try await model.captureDocument(original.document.id)
    XCTAssertEqual(deletedAgain.completeSnapshot?.text, "")
    guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Actual global replacement assertions failed; source/window retained.") }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }

  func testActualGraphemeDeletionAndShiftCutUndoAcrossNFDAndZWJWindowEdges() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try root(), model = try await open(scratch)
    let nfd = "e\u{301}", zwj = "👩🏽‍💻", edge = nfd + zwj
    let source = try await writeSource(scratch, edgeText: edge)
    try await model.importDocuments([source], flag: CancellationFlag())
    try await focusCurrentEditor(model)
    let original = try XCTUnwrap(model.pagedSelectedRecord)
    let commands = try XCTUnwrap(model.pagedCommands), edgeStart: UInt64 = 16_382
    let nfdEnd = edgeStart + UInt64(nfd.utf16.count), edgeEnd = edgeStart + UInt64(edge.utf16.count)
    XCTAssertEqual(original.document.revision.summary.bytes, 3_145_728 - 2 + UInt64(edge.utf8.count))
    XCTAssertNil(model.selectedDocument)

    // The actual mounted String begins at the combining mark. Backspace
    // must nevertheless remove the base and mark from the full source.
    _ = try await commands.navigate(toUTF16: edgeStart + 1,
      selectingUTF16: PagedNativeNavigationSelection(utf16Offset: nfdEnd, utf16Length: 0, affinity: .upstream))
    try XCTUnwrap(model.pagedInput?.activeView).doCommand(by: NSSelectorFromString("deleteBackward:"))
    try await commands.joinPendingCommand(); try await model.flush()
    let afterNFD = try XCTUnwrap(model.pagedSelectedRecord)
    XCTAssertEqual(afterNFD.document.revision.summary.bytes, original.document.revision.summary.bytes - UInt64(nfd.utf8.count))
    let nfdDeleted = try await sourceBytes(model, atUTF16: edgeStart)
    XCTAssertEqual(Data(nfdDeleted.prefix(zwj.utf8.count)), Data(zwj.utf8))
    commands.manager.undo(); try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, original.document.revision)

    // The next projection begins at the modifier, excluding the initial
    // pictograph. Its whole ZWJ cluster still forms one deletion/Undo group.
    _ = try await commands.navigate(toUTF16: nfdEnd + 2,
      selectingUTF16: PagedNativeNavigationSelection(utf16Offset: edgeEnd, utf16Length: 0))
    let truncatedZWJ = try XCTUnwrap(model.pagedInput?.activeView)
    XCTAssertFalse(truncatedZWJ.hasContainedCharacterCommand(NSSelectorFromString("deleteBackward:")))
    XCTAssertTrue(try XCTUnwrap(model.pagedInput).handlesDocumentCommand(NSSelectorFromString("deleteBackward:")))
    try XCTUnwrap(model.pagedInput?.activeView).doCommand(by: NSSelectorFromString("deleteBackward:"))
    try await commands.joinPendingCommand(); try await model.flush()
    let afterZWJ = try XCTUnwrap(model.pagedSelectedRecord)
    XCTAssertEqual(afterZWJ.document.revision.summary.bytes, original.document.revision.summary.bytes - UInt64(zwj.utf8.count))
    let zwjDeleted = try await sourceBytes(model, atUTF16: edgeStart)
    XCTAssertEqual(Data(zwjDeleted.prefix(nfd.utf8.count)), Data(nfd.utf8))
    XCTAssertEqual(try XCTUnwrap(zwjDeleted.dropFirst(nfd.utf8.count).first), 97)
    commands.manager.undo(); try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, original.document.revision)

    _ = try await commands.navigate(toUTF16: edgeStart - 1,
      selectingUTF16: PagedNativeNavigationSelection(utf16Offset: edgeStart, utf16Length: 0, affinity: .upstream))
    for _ in 0..<2 {
      try XCTUnwrap(model.pagedInput?.activeView).doCommand(by: NSSelectorFromString("moveForwardAndModifySelection:"))
      try await commands.joinPendingCommand()
    }
    let selected = try XCTUnwrap(model.pagedInput).currentDocumentSelection()
    XCTAssertEqual(selected.utf16Offset, edgeStart); XCTAssertEqual(selected.utf16Length, UInt64(edge.utf16.count))
    XCTAssertTrue(selected.focusAtEnd); XCTAssertEqual(selected.affinity, .upstream)
    try XCTUnwrap(model.pagedInput?.activeView).cut(nil)
    try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }, Data(edge.utf8))
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision.summary.bytes,
      original.document.revision.summary.bytes - UInt64(edge.utf8.count))
    commands.manager.undo(); try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, original.document.revision)
    XCTAssertEqual(try XCTUnwrap(model.pagedInput).currentDocumentSelection(), selected)
    let restored = try await sourceBytes(model, atUTF16: edgeStart)
    XCTAssertEqual(Data(restored.prefix(edge.utf8.count)), Data(edge.utf8))
    XCTAssertLessThanOrEqual(try XCTUnwrap(model.pagedInput?.activeView).string.utf8.count, PagedWorkingWindow.hardBytes)
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Actual grapheme/Shift/Cut assertions failed; source, clipboard result and native owners retained.")
    }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }

  func testActualVisualArrowsPreserveCocoaBidiTargetsAndOwnedShiftAnchorOnPagedSource() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try root(), model = try await open(scratch)
    let source = try await writeSource(scratch, edgeText: "אבג e\u{301}👩🏽‍💻 xyz\n")
    try await model.importDocuments([source], flag: CancellationFlag())
    try await focusCurrentEditor(model)
    let record = try XCTUnwrap(model.pagedSelectedRecord), commands = try XCTUnwrap(model.pagedCommands)
    let input = try XCTUnwrap(model.pagedInput), edgeStart: UInt64 = 16_382
    let initial = PagedNativeNavigationSelection(utf16Offset: edgeStart + 1, utf16Length: 0, affinity: .upstream)
    _ = try await commands.navigate(toUTF16: edgeStart - 8, selectingUTF16: initial)
    let view = try XCTUnwrap(input.activeView)
    Self.failedWindow?.contentView?.layoutSubtreeIfNeeded()
    if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
    let undoCount = Optional(try XCTUnwrap(model.pagedCommands).captureLogicalHistory().undo.count)

    // The native oracle is THIS actual product view, source and layout. In
    // this RTL run, visual Left must not be aliased to logical Backward.
    let left = NSSelectorFromString("moveLeft:")
    try view.performContainedDocumentCommand(left)
    let nativeLeft = try input.selectionForVisualMovement()
    XCTAssertGreaterThan(nativeLeft.focusUTF16, initial.focusUTF16)
    try input.setDocumentSelection(initial)
    let restoredEpoch = try input.observeSelection().selectionEpoch
    view.doCommand(by: left)
    try await commands.joinPendingCommand()
    let actualLeft = try input.currentDocumentSelection()
    XCTAssertEqual(actualLeft.focusUTF16, nativeLeft.focusUTF16)
    XCTAssertEqual(actualLeft.affinity, nativeLeft.affinity)
    XCTAssertGreaterThan(try input.observeSelection().selectionEpoch, restoredEpoch)

    try input.setDocumentSelection(initial)
    let shiftedLeft = NSSelectorFromString("moveLeftAndModifySelection:")
    try XCTUnwrap(input.activeView).performContainedDocumentCommand(shiftedLeft)
    let nativeShift = try input.selectionForVisualMovement()
    XCTAssertEqual(nativeShift.anchorUTF16, initial.focusUTF16)
    XCTAssertGreaterThan(nativeShift.focusUTF16, initial.focusUTF16)
    try input.setDocumentSelection(initial)
    try XCTUnwrap(input.activeView).doCommand(by: shiftedLeft)
    try await commands.joinPendingCommand()
    let actualShift = try input.currentDocumentSelection()
    XCTAssertEqual(actualShift, nativeShift)
    XCTAssertEqual(actualShift.anchorUTF16, initial.focusUTF16)

    let rightInitial = PagedNativeNavigationSelection(utf16Offset: edgeStart + 2, utf16Length: 0)
    try input.setDocumentSelection(rightInitial)
    let right = NSSelectorFromString("moveRight:")
    try XCTUnwrap(input.activeView).performContainedDocumentCommand(right)
    let nativeRight = try input.selectionForVisualMovement()
    XCTAssertLessThan(nativeRight.focusUTF16, rightInitial.focusUTF16)
    try input.setDocumentSelection(rightInitial)
    try XCTUnwrap(input.activeView).doCommand(by: right)
    try await commands.joinPendingCommand()
    let actualRight = try input.currentDocumentSelection()
    XCTAssertEqual(actualRight.focusUTF16, nativeRight.focusUTF16)
    XCTAssertEqual(actualRight.affinity, nativeRight.affinity)
    try input.setDocumentSelection(rightInitial)
    let shiftedRight = NSSelectorFromString("moveRightAndModifySelection:")
    try XCTUnwrap(input.activeView).performContainedDocumentCommand(shiftedRight)
    let nativeRightShift = try input.selectionForVisualMovement()
    XCTAssertEqual(nativeRightShift.anchorUTF16, rightInitial.focusUTF16)
    XCTAssertLessThan(nativeRightShift.focusUTF16, rightInitial.focusUTF16)
    try input.setDocumentSelection(rightInitial)
    try XCTUnwrap(input.activeView).doCommand(by: shiftedRight)
    try await commands.joinPendingCommand()
    XCTAssertEqual(try input.currentDocumentSelection(), nativeRightShift)

    // A local target inside the full NFD/ZWJ cluster is normalized without
    // converting that cluster, paragraph or document into a larger String.
    let nfdStart = edgeStart + 4, nfdEnd = nfdStart + 2, zwjEnd = nfdEnd + UInt64("👩🏽‍💻".utf16.count)
    let session = try XCTUnwrap(model.pagedSession)
    let logicalRead = try session.captureLogicalRead()
    let fullNFD = try await session.logicalGraphemeBoundary(logicalRead, atNativeUTF16: nfdStart + 1, forward: true).utf16
    let fullZWJ = try await session.logicalGraphemeBoundary(logicalRead, atNativeUTF16: nfdEnd + 2, forward: true).utf16
    let fullNFDStart = try await session.logicalGraphemeBoundary(logicalRead, atNativeUTF16: nfdStart + 1, forward: false).utf16
    let fullZWJStart = try await session.logicalGraphemeBoundary(logicalRead, atNativeUTF16: nfdEnd + 2, forward: false).utf16
    XCTAssertEqual(fullNFD, nfdEnd); XCTAssertEqual(fullZWJ, zwjEnd)
    XCTAssertEqual(fullNFDStart, nfdStart); XCTAssertEqual(fullZWJStart, nfdEnd)
    XCTAssertEqual(model.pagedSelectedRecord, record)
    XCTAssertEqual(Optional(try commands.captureLogicalHistory().undo.count), undoCount)
    XCTAssertFalse(commands.manager.canUndo); XCTAssertNil(input.firstRefusal)

    // Cocoa chooses an endpoint of the painted intersection; the managed
    // command collapses to that corresponding endpoint of the whole source.
    let global = PagedNativeNavigationSelection(utf16Offset: 0,
      utf16Length: record.document.revision.summary.utf16, focusAtEnd: true, affinity: .upstream)
    for arrow in [left, right] {
      try input.setDocumentSelection(global)
      let client = try XCTUnwrap(input.activeView), painted = client.selectedRange()
      let origin = try session.documentCoordinates().utf16Start
      try client.performContainedDocumentCommand(arrow)
      let endpoint = try input.selectionForVisualMovement()
      XCTAssertEqual(endpoint.utf16Length, 0)
      let choseLower = endpoint.focusUTF16 == origin + UInt64(painted.location)
      XCTAssertTrue(choseLower || endpoint.focusUTF16 == origin + UInt64(NSMaxRange(painted)))
      let expected = choseLower ? global.utf16Offset : global.utf16Offset + global.utf16Length
      try input.setDocumentSelection(global)
      client.doCommand(by: arrow)
      try await commands.joinPendingCommand()
      let collapsed = try input.currentDocumentSelection()
      XCTAssertEqual(collapsed.utf16Offset, expected); XCTAssertEqual(collapsed.utf16Length, 0)
      XCTAssertEqual(collapsed.affinity, endpoint.affinity)
      XCTAssertEqual(model.pagedSelectedRecord, record); XCTAssertFalse(commands.manager.canUndo)
    }

    // With the focus mounted at EOF, Shift+Left/Right use a true local caret
    // probe but preserve the global BOF anchor, not the painted local anchor.
    _ = try await commands.navigate(toUTF16: global.utf16Length - 4_096,
      selectingUTF16: PagedNativeNavigationSelection(utf16Offset: global.utf16Length, utf16Length: 0))
    var logical = global
    for (arrow, modified) in [(left, shiftedLeft), (right, shiftedRight)] {
      try input.setDocumentSelection(PagedNativeNavigationSelection(utf16Offset: logical.focusUTF16,
        utf16Length: 0, affinity: logical.affinity))
      let client = try XCTUnwrap(input.activeView)
      try client.performContainedDocumentCommand(arrow)
      let target = try input.selectionForVisualMovement()
      let expected = PagedNativeNavigationSelection(utf16Offset: min(logical.anchorUTF16, target.focusUTF16),
        utf16Length: max(logical.anchorUTF16, target.focusUTF16) - min(logical.anchorUTF16, target.focusUTF16),
        focusAtEnd: target.focusUTF16 >= logical.anchorUTF16, affinity: target.affinity)
      try input.setDocumentSelection(logical)
      client.doCommand(by: modified)
      try await commands.joinPendingCommand()
      logical = try input.currentDocumentSelection()
      XCTAssertEqual(logical, expected); XCTAssertEqual(logical.anchorUTF16, 0)
      XCTAssertEqual(model.pagedSelectedRecord, record); XCTAssertFalse(commands.manager.canUndo)
    }
    _ = try await commands.navigate(toUTF16: edgeStart - 8, selectingUTF16: initial)
    let heldView = try XCTUnwrap(input.activeView)

    // Changing both native endpoints supplies no actual independent anchor.
    // Even opposite affinity cannot justify inventing one for Shift+Arrow.
    heldView.setSelectedRange(NSRange(location: 10, length: 2), affinity: .downstream, stillSelecting: false)
    let unknown = try input.observeSelection()
    XCTAssertThrowsError(try commands.requestVisualGraphemeMovement(shiftedLeft))
    XCTAssertEqual(try input.observeSelection(), unknown)
    XCTAssertNil(input.firstRefusal); XCTAssertFalse(commands.isNavigating)
    try input.setDocumentSelection(initial)
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Actual visual-arrow assertions failed; source, Cocoa target and physical owners retained.")
    }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }

  func testActualStreamedClipboardCutPasteUndoRedoKeepsWholeSourceAndOriginalGlobalSelection() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try root(), model = try await open(scratch)
    let source = try await writeSource(scratch, edgeText: "e\u{301}👩🏽‍💻")
    try await model.importDocuments([source], flag: CancellationFlag())
    try await focusCurrentEditor(model)
    let original = try XCTUnwrap(model.pagedSelectedRecord)
    let engine = try XCTUnwrap(model.pagedEngine), commands = try XCTUnwrap(model.pagedCommands)
    let digest = try await engine.wholeTextSha256(original.document.revision)
    let selection = PagedNativeNavigationSelection(utf16Offset: 0,
      utf16Length: original.document.revision.summary.utf16, focusAtEnd: false, affinity: .upstream)
    try XCTUnwrap(model.pagedInput).setDocumentSelection(selection)
    let attachments = model.pendingAttachments
    // Deliver actual Cocoa commands through the lexical native scope. Cut
    // waits for the streamed file's real pasteboard publication before delete.
    try XCTUnwrap(model.pagedInput?.activeView).doCommand(by: NSSelectorFromString("cut:"))
    try await commands.joinPendingCommand(); try await model.flush()
    let cut = try XCTUnwrap(model.pagedSelectedRecord)
    XCTAssertEqual(cut.document.revision.summary.bytes, 0)
    let clipboard = try XCTUnwrap(try PagedClipboardTextFile.read(.general))
    let fileBytes = try await Task.detached {
      let opened = try clipboard.open()
      let count = opened.expectedBytes
      try opened.close()
      return count
    }.value
    XCTAssertEqual(fileBytes, original.document.revision.summary.bytes)
    XCTAssertNil(NSPasteboard.general.string(forType: .string), "Large Copy publishes a real file, not an eager GB text buffer.")
    try XCTUnwrap(model.pagedInput?.activeView).doCommand(by: NSSelectorFromString("paste:"))
    try await commands.joinPendingCommand(); try await model.flush()
    let pasted = try XCTUnwrap(model.pagedSelectedRecord)
    XCTAssertEqual(pasted.document.revision.summary, original.document.revision.summary)
    XCTAssertEqual(pasted.historyGeneration, cut.historyGeneration + 1, "The imported tree is one canonical Paste group.")
    let pastedDigest = try await engine.wholeTextSha256(pasted.document.revision)
    XCTAssertEqual(pastedDigest, digest)
    XCTAssertEqual(model.pendingAttachments, attachments, "Our explicit text-file marker must not become an attachment.")
    XCTAssertLessThanOrEqual(try XCTUnwrap(model.pagedInput?.activeView).string.utf8.count, PagedWorkingWindow.hardBytes)
    XCTAssertEqual(engine.custodySnapshot.jobs, 0)
    XCTAssertFalse(engine.custodySnapshot.items.contains { item in
      if case .operation = item.purpose { return true }; return false
    }, "The real import output is consumed by the physical installation join.")

    commands.manager.undo(); try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, cut.document.revision)
    commands.manager.undo(); try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, original.document.revision)
    XCTAssertEqual(try XCTUnwrap(model.pagedInput).currentDocumentSelection(), selection)
    commands.manager.redo(); try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, cut.document.revision)
    commands.manager.redo(); try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, pasted.document.revision)
    let redoneDigest = try await engine.wholeTextSha256(try XCTUnwrap(model.pagedSelectedRecord).document.revision)
    XCTAssertEqual(redoneDigest, digest)
    XCTAssertLessThanOrEqual(try XCTUnwrap(model.pagedInput?.activeView).string.utf8.count, PagedWorkingWindow.hardBytes)
    guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Actual streamed Paste assertions failed; source/window retained.") }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }

  func testActualFailedStreamedCopyDoesNotPoisonTheNextCopyOrDestroyThePriorClipboard() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try root(), model = try await open(scratch.appendingPathComponent("workspace"))
    let source = try await writeSource(scratch, edgeText: "e\u{301}🙂")
    try await model.importDocuments([source], flag: CancellationFlag())
    try await focusCurrentEditor(model)
    let record = try XCTUnwrap(model.pagedSelectedRecord)
    let commands = try XCTUnwrap(model.pagedCommands), input = try XCTUnwrap(model.pagedInput)
    let publisher = try XCTUnwrap(model.pagedPublisher)
    let selection = PagedNativeNavigationSelection(utf16Offset: 0,
      utf16Length: record.document.revision.summary.utf16, focusAtEnd: true)
    try input.setDocumentSelection(selection)
    let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false).appendingPathComponent("Bloom/Clipboard", isDirectory: true)
      .appendingPathComponent(publisher.storeID.uuidString.lowercased(), isDirectory: true)
    // Arm cleanup before the detached negative control can change permissions.
    defer {
      if FileManager.default.fileExists(atPath: directory.path) {
        do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        catch { XCTFail("The owned clipboard-directory permission cleanup failed: \(error.localizedDescription)") }
      }
    }
    let expectedFailure = try await Task.detached {
      let manager = FileManager.default
      try manager.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
      do {
        _ = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        throw BoomError.invalid("The real clipboard-directory permission negative control was not denied.")
      } catch let error as CocoaError where error.code == .fileReadNoPermission {
        return error.localizedDescription
      }
    }.value
    let board = NSPasteboard.general
    board.clearContents(); XCTAssertTrue(board.setString("prior public clipboard", forType: .string))
    var statuses: [String] = []
    let observation = model.$status.sink { statuses.append($0) }
    defer { observation.cancel() }
    try XCTUnwrap(input.activeView).doCommand(by: NSSelectorFromString("copy:"))
    try await commands.joinPendingCommand()
    // The existing backup owner joins the actual prior clipboard producer.
    // Its already-independent failure handling must not manufacture a Copy pass.
    _ = try await model.exportWorkspaceBackup(to: scratch.appendingPathComponent("after-failed-copy.bloom")).value
    try await model.joinWorkspaceOperation()
    XCTAssertTrue(statuses.contains(expectedFailure), "The first actual streamed Copy must report its real permission failure.")
    XCTAssertEqual(board.string(forType: .string), "prior public clipboard")
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, record.document.revision)
    try await Task.detached {
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }.value
    try await focusCurrentEditor(model)
    try input.setDocumentSelection(selection)
    try XCTUnwrap(input.activeView).doCommand(by: NSSelectorFromString("copy:"))
    try await commands.joinPendingCommand()
    _ = try await model.exportWorkspaceBackup(to: scratch.appendingPathComponent("after-successful-copy.bloom")).value
    try await model.joinWorkspaceOperation()
    let clipboard = try XCTUnwrap(try PagedClipboardTextFile.read(board))
    let exactBytes = try await Task.detached {
      try Data(contentsOf: clipboard.url) == Data(contentsOf: source)
    }.value
    XCTAssertTrue(exactBytes, "The second actual Copy must publish every selected byte despite the retained first failure.")
    XCTAssertNil(board.string(forType: .string), "This is the actual streamed file route, not eager whole text.")
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, record.document.revision)
    XCTAssertEqual(try input.currentDocumentSelection(), selection)
    XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Actual failed-then-successful clipboard assertions failed; the public native graph is retained.")
    }
    board.clearContents()
    try await joinedClose(model)
    try await Task.detached { try FileManager.default.removeItem(at: directory) }.value
    try await removeJoinedScratch(scratch)
  }

  func testActualStreamedClipboardDescriptorAboveGiBDoesNotReadOrMaterializeItsBody() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try root(), file = scratch.appendingPathComponent("public-beyond-gib.txt")
    let length: UInt64 = 1_073_741_825
    let observed = try await Task.detached {
      guard FileManager.default.createFile(atPath: file.path, contents: nil,
        attributes: [.posixPermissions: 0o600]) else {
        throw BoomError.unavailable("Could not create the public sparse metadata fixture.")
      }
      let writer = try FileHandle(forWritingTo: file)
      var writerCloseAttempted = false
      do {
        // A real ordinary sparse file. No GiB buffer or body scan is needed
        // to admit and pin the descriptor; full UTF8 import is separate.
        try writer.truncate(atOffset: length)
        writerCloseAttempted = true; try writer.close()
      } catch {
        let original = error
        if !writerCloseAttempted {
          do { try writer.close() }
          catch { throw BoundedWorkspaceCleanupFailure(original: original, cleanup: error) }
        }
        throw original
      }
      let opened = try PagedClipboardTextFile.Opened(url: file)
      var closeAttempted = false
      do {
        try opened.admit()
        let result = (opened.expectedBytes, try opened.file.offset())
        closeAttempted = true; try opened.close()
        return result
      } catch {
        let original = error
        if !closeAttempted {
          do { try opened.close() }
          catch { throw BoundedWorkspaceCleanupFailure(original: original, cleanup: error) }
        }
        throw original
      }
    }.value
    XCTAssertEqual(observed.0, length)
    XCTAssertEqual(observed.1, 0, "Descriptor admission must not consume or assemble the text body.")
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Actual larger-file descriptor assertions failed; its sparse public fixture is retained.")
    }
    try await removeJoinedScratch(scratch)
  }

  func testActualClipboardTextIntentCapturesOriginalDescriptorAcrossBoardAndPathChanges() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try root(), source = try await writeSource(scratch)
    let board = NSPasteboard(name: NSPasteboard.Name("Bloom-text-intent-\(UUID().uuidString)"))
    let plainURL = NSPasteboardItem()
    XCTAssertTrue(plainURL.setString(source.absoluteString, forType: .fileURL))
    board.clearContents(); XCTAssertTrue(board.writeObjects([plainURL]))
    XCTAssertNil(try PagedClipboardTextFile.read(board), "An unmarked file URL remains ordinary attachment Paste.")
    let explicit = try XCTUnwrap(try PagedClipboardTextFile.read(board, explicitlyPlainText: true))
    try explicit.admitCurrent()
    try PagedClipboardTextFile.write(source, to: board)
    XCTAssertThrowsError(try explicit.admitCurrent(), "A different board generation cannot reuse an uncaptured Paste intent.")
    let marked = try XCTUnwrap(try PagedClipboardTextFile.read(board))
    try marked.admitCurrent()
    let opened = try await Task.detached { try marked.open() }.value
    // New clipboard content is independent of the descriptor already owned
    // by the accepted Paste. Only a new uncaptured use of marked is stale.
    board.clearContents(); XCTAssertTrue(board.setString("different", forType: .string))
    XCTAssertThrowsError(try marked.admitCurrent())
    try await Task.detached {
      var closeAttempted = false
      do {
        let old = scratch.appendingPathComponent("retained-original-source.md")
        try FileManager.default.moveItem(at: source, to: old)
        guard FileManager.default.createFile(atPath: source.path, contents: Data("replacement".utf8)) else {
          throw BoomError.unavailable("Could not prepare the distinct public filename witness.")
        }
        try opened.admit()
        guard opened.expectedBytes == 3_145_728,
          try opened.file.read(upToCount: 64) == Data(repeating: UInt8(97), count: 64) else {
          throw BoomError.invalid("Captured Paste did not retain the original descriptor bytes.")
        }
        // An in-place write to that SAME captured inode remains a torn-input
        // refusal; changing the pathname was not a new source capability.
        let writer = try FileHandle(forWritingTo: old)
        var writerCloseAttempted = false
        do {
          try writer.write(contentsOf: Data("changed".utf8)); try writer.synchronize()
          writerCloseAttempted = true; try writer.close()
        } catch {
          let original = error
          if !writerCloseAttempted {
            do { try writer.close() }
            catch { throw BoundedWorkspaceCleanupFailure(original: original, cleanup: error) }
          }
          throw original
        }
        do { try opened.admit(); throw BoomError.invalid("The captured inode's in-place mutation was admitted.") }
        catch let error as BoomError {
          guard case .stale = error else { throw error }
        }
        closeAttempted = true; try opened.close()
      } catch {
        let original = error
        if !closeAttempted {
          do { try opened.close() }
          catch { throw BoundedWorkspaceCleanupFailure(original: original, cleanup: error) }
        }
        throw original
      }
    }.value
    board.clearContents()
    guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Actual clipboard capture assertions failed; public files retained.") }
    try await removeJoinedScratch(scratch)
  }

  func testActualStaleClipboardBeforeCaptureLeavesLaterNativeTypingAndUndoUsable() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try diagnosticRoot(), model = try await open(scratch, requiresActualKeyWindow: false)
    let source = try await writeSource(scratch)
    let input = try XCTUnwrap(model.pagedInput), view = try XCTUnwrap(input.activeView)
    let commands = try XCTUnwrap(model.pagedCommands), session = try XCTUnwrap(model.pagedSession)
    let record = try XCTUnwrap(model.pagedSelectedRecord), generation = session.generation
    let capture = try await model.captureDocument(record.document.id)
    let before = try XCTUnwrap(capture.completeSnapshot).text
    let board = NSPasteboard(name: NSPasteboard.Name("Bloom-before-Paste-\(UUID().uuidString)"))
    try PagedClipboardTextFile.write(source, to: board)
    let original = try XCTUnwrap(try PagedClipboardTextFile.read(board))
    board.clearContents(); XCTAssertTrue(board.setString("new clipboard", forType: .string))
    XCTAssertThrowsError(try model.pasteDocumentTextFile(original, from: view))
    XCTAssertEqual(model.pagedSelectedRecord, record); XCTAssertEqual(session.generation, generation)
    XCTAssertNil(input.firstRefusal); XCTAssertNil(view.inputBinding?.firstRefusal)
    XCTAssertNil(view.boundedStorage.mutationFailure); XCTAssertNil(model.errorMessage)
    view.setSelectedRange(NSRange(location: before.utf16.count, length: 0))
    view.insertText("p", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await commands.joinPendingCommand(); try await model.flush()
    let edited = try await model.captureDocument(record.document.id)
    XCTAssertEqual(edited.completeSnapshot?.text, before + "p")
    commands.manager.undo(); try await commands.joinPendingCommand(); try await model.flush()
    let undone = try await model.captureDocument(record.document.id)
    XCTAssertEqual(undone.completeSnapshot?.text, before)
    XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure); XCTAssertNil(model.errorMessage)
    board.clearContents()
    guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Before-capture clipboard assertions failed; public source retained.") }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }

  func testActualCompletedPasteImportCancellationJoinsOutputWithoutSourceOrHistoryMutation() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try root(), model = try await open(scratch)
    let source = try await writeSource(scratch)
    let engine = try XCTUnwrap(model.pagedEngine), commands = try XCTUnwrap(model.pagedCommands)
    let original = try XCTUnwrap(model.pagedSelectedRecord)
    let selected = try XCTUnwrap(model.pagedInput).currentDocumentSelection()
    var discarded = false
    let task = try commands.requestDocumentImportedReplacement(selected, importing: { record in
      let opened = try await Task.detached { try PagedClipboardTextFile.Opened(url: source) }.value
      let output: PagedTextCustodiedValue<PagedTextImportedRevision>
      do {
        output = try await engine.importUTF8Retaining(documentID: record.source.sourceRevision.documentID, from: opened.file,
          expectedBytes: opened.expectedBytes, priority: .foreground)
      } catch {
        let original = error
        do { try opened.close() }
        catch { throw BoundedWorkspaceCleanupFailure(original: original, cleanup: error) }
        throw original
      }
      var closeAttempted = false
      do {
        try await Task.detached { try opened.admit() }.value
        closeAttempted = true; try await Task.detached { try opened.close() }.value
      }
      catch {
        var original: Error = error
        if !closeAttempted {
          do { try await Task.detached { try opened.close() }.value }
          catch { original = BoundedWorkspaceCleanupFailure(original: original, cleanup: error) }
        }
        do { try await engine.abandonJoinedRootOutput(output.lease) }
        catch { throw PagedTextCustodyHandoffFailure(original: original, handoff: error, lease: output.lease) }
        throw original
      }
      withUnsafeCurrentTask { $0?.cancel() } // after the actual completed import, before native writer admission
      return output
    }, discard: { lease in
      try await engine.abandonJoinedRootOutput(lease); discarded = true
    })
    do { _ = try await task.value; XCTFail("Cancelled source preparation must not publish Paste.") }
    catch is CancellationError { }
    XCTAssertTrue(discarded, "The actual joined import lease needs an explicit abandonment.")
    XCTAssertEqual(model.pagedSelectedRecord, original)
    XCTAssertEqual(try XCTUnwrap(model.pagedInput).currentDocumentSelection(), selected)
    XCTAssertEqual(engine.custodySnapshot.jobs, 0)
    XCTAssertFalse(engine.custodySnapshot.items.contains { item in
      if case .operation = item.purpose { return true }; return false
    })
    try await model.flush()
    guard (testRun?.failureCount ?? 0) == failures else { throw BoomError.invalid("Actual cancelled Paste assertions failed; source/window retained.") }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }

  func testActualOrdinaryRenameRetiresOldClientAndTrashRetainsFileSourceWithoutRemovingDraft() async throws {
    let failureCount = testRun?.failureCount ?? 0
    let scratch = try root(), model = try await open(scratch)
    let oldView = try XCTUnwrap(model.pagedInput?.activeView)
    let oldContext = try XCTUnwrap(oldView.inputContext)
    let exportedText = "A small é🙂 source.\n"
    oldView.insertText(exportedText, replacementRange: NSRange(location: 0, length: 0))
    try await model.flush()
    let capturedExport = try XCTUnwrap(model.pagedSelectedRecord)
    let exportURL = scratch.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent("Bloom-public-export-\(UUID().uuidString).md")
    Self.failedExport = exportURL
    let exportTask = try model.exportPagedDocument(to: exportURL)
    let publishedURL = try await exportTask.value
    XCTAssertEqual(publishedURL, exportURL)
    let firstExport = try await readSmallExport(exportURL)
    XCTAssertEqual(firstExport, Data(exportedText.utf8))
    oldView.insertText("Later source input.", replacementRange: NSRange(location: oldView.string.utf16.count, length: 0))
    try await model.flush()
    let before = try XCTUnwrap(model.pagedSelectedRecord)
    XCTAssertNotEqual(before.document.revision, capturedExport.document.revision)
    let retainedExport = try await readSmallExport(exportURL)
    XCTAssertEqual(retainedExport, Data(exportedText.utf8), "A later native seal never relabels an already published immutable export.")
    let cancelledExport = PagedTextCancellation()
    let cancelledTask = try model.exportPagedDocument(to: exportURL, cancellation: cancelledExport)
    model.cancelExport(to: exportURL)
    do { _ = try await cancelledTask.value; XCTFail("The actual cancelled export must not publish a newer version.") }
    catch is CancellationError {} catch { throw error }
    XCTAssertTrue(cancelledExport.isCancelled, "Stopping the actual producer also reaches its existing explicit stream/publication token.")
    let unchangedExport = try await readSmallExport(exportURL)
    XCTAssertEqual(unchangedExport, Data(exportedText.utf8))
    model.draft = "Keep this source owner's unsent text."
    try await model.flush()
    model.renameDocument(before.document.id, to: "Renamed")
    try await model.joinWorkspaceOperation()
    let renamed = try XCTUnwrap(model.pagedSelectedRecord)
    XCTAssertEqual(model.selectedDocumentIndex?.title, "Renamed")
    XCTAssertEqual(renamed.document.revision, before.document.revision)
    XCTAssertEqual(renamed.historyPage, before.historyPage)
    XCTAssertEqual(oldView.inputBinding?.state, .active)
    XCTAssertEqual(model.pagedSelectedRecord, renamed)
    // Use the actual public Model transition, preserving its real confirmation.
    // Modal confirmation cannot be fabricated by this component control. The
    // direct source consumer below is the SAME Model method, not a SQL stand-in.
    try await model.trashPagedDocuments([before.document.id])
    XCTAssertNil(model.selectedDocumentID); XCTAssertNil(model.pagedViewport)
    XCTAssertFalse(model.hasComposerOwner)
    let ownerless = NSHostingView(rootView: PagedWorkspaceComposer(model: model))
    Self.failedWindow?.contentView = ownerless
    Self.failedWindow?.layoutIfNeeded()
    let composer = try XCTUnwrap(chatTextView(in: ownerless))
    let retainedDraft = model.draft, retainedDisplay = composer.string
    XCTAssertFalse(composer.isEditable)
    composer.insertText("Ownerless input", replacementRange: NSRange(location: 0, length: 0))
    composer.setMarkedText("Ownerless IME", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertFalse(composer.hasMarkedText())
    XCTAssertEqual(model.draft, retainedDraft); XCTAssertEqual(composer.string, retainedDisplay)
    XCTAssertNil(composer.onSend); XCTAssertNil(composer.onCancel); XCTAssertNil(composer.onAttachments); XCTAssertNil(composer.onFocus)
    let engine = try XCTUnwrap(model.pagedEngine), publisher = try XCTUnwrap(model.pagedPublisher)
    let state = try await model.store.loadState()
    XCTAssertTrue(state.archivedDocuments?.contains(where: { $0.id == before.document.id }) == true)
    let retained = try await engine.currentDocumentRecordRetaining(publisher, documentID: before.document.id)
    XCTAssertEqual(retained.value.document.revision, renamed.document.revision)
    try await engine.abandonJoinedRootOutput(retained.lease)
    let owner = ComposerOwner(kind: .document, id: before.document.id)
    XCTAssertEqual(state.composerDrafts?.first(where: { $0.owner == owner })?.text, "Keep this source owner's unsent text.")
    guard (testRun?.failureCount ?? 0) == failureCount else { throw BoomError.invalid("Actual ordinary assertions failed; owner/evidence retained.") }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }

  func testActualJoinedEditSaveRenameShutdownAndZeroEntryCancellationPreserveColdSource() async throws {
    let failureCount = testRun?.failureCount ?? 0
    let scratch = try root(), model = try await open(scratch)
    let engine = try XCTUnwrap(model.pagedEngine)
    let documentID = try XCTUnwrap(model.pagedSelectedRecord).document.id
    let view = try XCTUnwrap(model.pagedInput?.activeView)
    let source = "The actual é🙂 source survives ordered saves."
    view.insertText(source, replacementRange: view.selectedRange())
    try await model.flush()
    let before = try XCTUnwrap(model.pagedSelectedRecord)
    model.draft = "The actual reserved save must precede rename."
    // Reserve the real save and transition on Main before either task yields.
    // Their actual joins and cold readback are the oracle; this does not force
    // or claim the removed SQL-era held-queue admission interleaving.
    let actualSave = try model.beginPagedWorkspaceSave()
    model.renameDocument(documentID, to: "After reserved save")
    try await actualSave.value
    try await model.joinWorkspaceOperation()
    XCTAssertEqual(model.pagedSelectedRecord?.document.title, "After reserved save")
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, before.document.revision)
    let afterRename = try await model.captureDocument(documentID)
    XCTAssertEqual(afterRename.completeSnapshot?.text, source)
    // Both calls run synchronously before the new operation enters its body.
    let unchanged = try XCTUnwrap(model.pagedSelectedRecord)
    try model.newDocument(); model.cancel()
    try await model.joinWorkspaceOperation()
    XCTAssertEqual(model.pagedSelectedRecord, unchanged)
    try await model.flush()

    model.draft = "The reserved save must durably finish before shutdown."
    let finalSave = try model.beginPagedWorkspaceSave()
    let closing = Task { try await model.shutdown() }
    try await finalSave.value
    try await closing.value
    XCTAssertNil(model.pagedEngine); XCTAssertNil(model.pagedViewport)
    XCTAssertTrue(engine.custodySnapshot.items.isEmpty)
    XCTAssertEqual(engine.custodySnapshot.jobs, 0)
    guard (testRun?.failureCount ?? 0) == failureCount else {
      throw BoomError.invalid("Actual ordered save/close assertions failed; owner and public source retained.")
    }
    Self.failedWindow?.orderOut(nil); Self.failedWindow?.close()
    Self.failedWindow = nil; Self.failedModel = nil
    let reopened = try await open(scratch)
    XCTAssertEqual(reopened.selectedDocumentIndex?.title, "After reserved save")
    XCTAssertEqual(reopened.pagedSelectedRecord?.document.revision, before.document.revision)
    XCTAssertEqual(reopened.draft, "The reserved save must durably finish before shutdown.")
    let coldSource = try await reopened.captureDocument(documentID)
    XCTAssertEqual(coldSource.completeSnapshot?.text, source)
    guard (testRun?.failureCount ?? 0) == failureCount else {
      throw BoomError.invalid("Actual cold source/draft receiving failed; file records and owner retained.")
    }
    try await joinedClose(reopened); try await removeJoinedScratch(scratch)
  }

  /// Isolated retained-terminal source case: marked input makes physical close
  /// inadmissible. Its actual text/client/controller remains retained on failure.
  func testActualOrdinarySelectionRefusesMarkedInputAndRetainsSourceInsteadOfClosingOrDiscardingIt() async throws {
    guard ProcessInfo.processInfo.environment["BLOOM_BOUNDED_WORKSPACE_CASE"] == #function else {
      XCTFail("Nominate this retained-terminal exact case in its own process; zero skips."); return
    }
    let scratch = try root(), model = try await open(scratch)
    let first = try XCTUnwrap(model.pagedSelectedRecord)
    let source = try await writeSource(scratch)
    try await model.importDocuments([source], flag: CancellationFlag())
    let active = try XCTUnwrap(model.pagedSelectedRecord)
    let view = try XCTUnwrap(model.pagedInput?.activeView), identity = try XCTUnwrap(view.inputBinding?.identity)
    view.setMarkedText("marked", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(view.hasMarkedText())
    do { try await model.selectPagedDocument(first.document.id); XCTFail("Actual pinned input must refuse selection.") }
    catch { XCTAssertTrue(view.hasMarkedText()) }
    XCTAssertTrue(model.pagedInput?.activeView === view)
    XCTAssertEqual(view.inputBinding?.identity, identity); XCTAssertEqual(view.inputBinding?.state, .active)
    XCTAssertEqual(model.selectedDocumentID, active.document.id)
    do { try await model.shutdown(); XCTFail("An unjoined marked source must not grant close.") } catch {}
    XCTAssertNotNil(model.pagedEngine)
    print("RETAINED_TERMINAL actual ordinary marked input/source/controller at \(scratch.path); no false close or scratch deletion.")
  }

  /// This is the ordinary Send boundary through its actual Work prelude and
  /// native finish/flush, without crossing canInfer or loading a model. The
  /// empty attachment entry invokes the same real chat-destination factory as
  /// ensureChatForSend; attach itself admits no attachment work for [] input.
  private func runActualChatNativeTransition(source: String, marked: Bool = false,
    directUnmark: Bool = false) async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try diagnosticRoot(), model = try await open(scratch, requiresActualKeyWindow: false)
    let record = try XCTUnwrap(model.pagedSelectedRecord)
    let input = try XCTUnwrap(model.pagedInput), view = try XCTUnwrap(input.activeView)
    let window = try XCTUnwrap(Self.failedWindow), host = try XCTUnwrap(window.contentView)
    XCTAssertEqual(view.string, ""); XCTAssertTrue(model.state.chats.isEmpty)
    XCTAssertNil(model.selectedMLXRunner); XCTAssertNil(model.completionRunner)
    if !source.isEmpty {
      view.insertText(source, replacementRange: NSRange(location: NSNotFound, length: 0))
      try await model.pagedCommands?.joinPendingCommand(); try await model.flush()
    }
    if marked {
      view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      XCTAssertTrue(view.hasMarkedText())
    } else { XCTAssertFalse(view.hasMarkedText()) }
    XCTAssertNil(view.inputBinding?.firstRefusal); XCTAssertNil(view.boundedStorage.mutationFailure)
    model.draft = "hello"
    host.layoutSubtreeIfNeeded()
    print("SDK_SEND_NATIVE_BOUNDARY chat-destination")
    model.attachToCurrentChat([])
    XCTAssertEqual(model.state.chats.count, 1)
    XCTAssertEqual(model.selectedChat?.attachedDocumentID, record.document.id)
    XCTAssertEqual(model.draft, "hello")
    host.layoutSubtreeIfNeeded()
    let composer = try XCTUnwrap(chatTextView(in: host))
    XCTAssertFalse(composer.textStorage === view.textStorage)
    guard window.makeFirstResponder(composer), window.firstResponder === composer else {
      throw BoomError.unavailable("The actual Send-boundary composer did not acquire its window responder.")
    }
    var enteredBodies = 0
    print("SDK_SEND_NATIVE_BOUNDARY work-prelude")
    model.work("Public native Send-boundary diagnostic") { flag in
      enteredBodies += 1
      try flag.check()
      print("SDK_SEND_NATIVE_BOUNDARY finish-composition")
      if directUnmark { view.unmarkText() }
      else { model.finishComposition() }
      try await model.flush()
      host.layoutSubtreeIfNeeded()
      let busyComposer = try XCTUnwrap(self.chatTextView(in: host))
      XCTAssertTrue(busyComposer.isEditable)
      XCTAssertFalse(busyComposer.textStorage === view.textStorage)
      print("SDK_SEND_NATIVE_BOUNDARY clear-composer")
      model.draft = ""
    }
    XCTAssertTrue(model.isBusy)
    try await model.joinWorkspaceOperation() // Actual retained foreground Task.
    try await model.flush()
    host.layoutSubtreeIfNeeded()
    let expected = source + (marked ? "に" : "")
    let capture = try await model.captureDocument(record.document.id)
    XCTAssertEqual(enteredBodies, 1); XCTAssertFalse(model.isBusy)
    XCTAssertNil(model.errorMessage)
    XCTAssertNil(view.inputBinding?.firstRefusal); XCTAssertNil(view.boundedStorage.mutationFailure)
    XCTAssertTrue(input.activeView === view); XCTAssertFalse(view.hasMarkedText())
    XCTAssertEqual(Data(view.string.utf8), Data(expected.utf8))
    XCTAssertEqual(capture.completeSnapshot?.text, expected)
    XCTAssertEqual(try input.currentDocumentSelection().utf16Offset, UInt64(expected.utf16.count))
    XCTAssertEqual(model.draft, "")
    XCTAssertEqual(try XCTUnwrap(chatTextView(in: host)).string, "")
    XCTAssertNil(model.selectedMLXRunner); XCTAssertNil(model.completionRunner)
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Actual Send native-boundary assertions failed; source and receivers retained.")
    }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }

  func testActualEmptyDocumentDirectUnmarkWorkBoundaryWithoutModel() async throws {
    try await runActualChatNativeTransition(source: "", directUnmark: true)
  }
  func testActualEmptyDocumentGuardedFinishWorkBoundaryWithoutModel() async throws {
    try await runActualChatNativeTransition(source: "")
  }
  func testActualNonemptyDocumentGuardedFinishWorkBoundaryWithoutModel() async throws {
    try await runActualChatNativeTransition(source: "Some ")
  }
  func testActualMarkedDocumentWorkBoundaryCommitsNativeCompositionWithoutModel() async throws {
    try await runActualChatNativeTransition(source: "Cafe\u{301} ", marked: true)
  }

  /// A real current TextKit storage primitive need not originate inside the
  /// view's lexical key wrapper. Retired callbacks cannot write the new arena.
  func testActualCurrentStoragePrimitiveAndRetiredCallbacksKeepLaterTypingUndoAndRedoUsable() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try diagnosticRoot(), model = try await open(scratch, requiresActualKeyWindow: false)
    let initial = try XCTUnwrap(model.pagedSelectedRecord)
    let input = try XCTUnwrap(model.pagedInput), commands = try XCTUnwrap(model.pagedCommands)
    let view = try XCTUnwrap(input.activeView), session = try XCTUnwrap(model.pagedSession)
    XCTAssertEqual(view.string, ""); XCTAssertTrue(view.inputCommandIsClosed)
    XCTAssertEqual(view.inputBinding?.commandDepth, 0)
    let storage = view.boundedStorage
    let previousDelegate = storage.delegate
    let observation = CharacterUndoObservation(view: view)
    storage.delegate = observation
    defer { storage.delegate = previousDelegate }
    let generation = session.generation
    view.boundedStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "a")
    XCTAssertGreaterThan(observation.characterNotifications, 0)
    XCTAssertFalse(observation.exposedManagerDuringCharacters)
    XCTAssertFalse(storage.hasOpenCharacterTransaction)
    XCTAssertTrue(view.undoManager === commands.manager)
    XCTAssertEqual(session.generation, generation + 1)
    XCTAssertEqual(view.string, "a")
    XCTAssertNil(view.inputBinding?.firstRefusal); XCTAssertNil(view.boundedStorage.mutationFailure)
    view.setSelectedRange(NSRange(location: 1, length: 0))
    try await commands.joinPendingCommand(); try await model.flush()
    let first = try await model.captureDocument(initial.document.id)
    XCTAssertEqual(first.completeSnapshot?.text, "a")
    XCTAssertTrue(commands.manager.canUndo)
    view.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await commands.joinPendingCommand(); try await model.flush()
    let second = try await model.captureDocument(initial.document.id)
    XCTAssertEqual(second.completeSnapshot?.text, "ab")
    XCTAssertEqual(Optional(try commands.captureLogicalHistory().undo.count), 2)

    let oldBinding = try XCTUnwrap(view.inputBinding), oldStorage = view.boundedStorage
    let oldContext = try XCTUnwrap(view.inputContext), oldClient = try XCTUnwrap(oldContext.client as? PagedNativeTextInputClient)
    commands.manager.undo(); try await commands.joinPendingCommand(); try await model.flush()
    let undone = try await model.captureDocument(initial.document.id)
    XCTAssertEqual(undone.completeSnapshot?.text, "a")
    let current = try XCTUnwrap(input.activeView)
    XCTAssertTrue(current === view); XCTAssertEqual(oldBinding.state, .retired)
    XCTAssertFalse(current.boundedStorage === oldStorage); XCTAssertFalse(oldClient.isRetired)
    XCTAssertTrue(current.inputContext === oldContext)
    let stableRecord = try XCTUnwrap(model.pagedSelectedRecord), stableGeneration = session.generation
    let stableSelection = try input.currentDocumentSelection()
    oldStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "z")
    XCTAssertEqual(model.pagedSelectedRecord, stableRecord); XCTAssertEqual(session.generation, stableGeneration)
    XCTAssertEqual(try input.currentDocumentSelection(), stableSelection)
    XCTAssertEqual(current.string, "a"); XCTAssertFalse(current.hasMarkedText())
    XCTAssertNil(input.firstRefusal); XCTAssertNil(current.inputBinding?.firstRefusal)
    XCTAssertNil(current.boundedStorage.mutationFailure)

    commands.manager.redo(); try await commands.joinPendingCommand(); try await model.flush()
    let redone = try await model.captureDocument(initial.document.id)
    XCTAssertEqual(redone.completeSnapshot?.text, "ab")
    let typing = try XCTUnwrap(input.activeView)
    typing.setSelectedRange(NSRange(location: 2, length: 0))
    typing.insertText("c", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await commands.joinPendingCommand(); try await model.flush()
    let later = try await model.captureDocument(initial.document.id)
    XCTAssertEqual(later.completeSnapshot?.text, "abc")
    XCTAssertNil(input.firstRefusal); XCTAssertNil(typing.boundedStorage.mutationFailure)
    commands.manager.undo(); try await commands.joinPendingCommand(); try await model.flush()
    let laterUndone = try await model.captureDocument(initial.document.id)
    XCTAssertEqual(laterUndone.completeSnapshot?.text, "ab")
    commands.manager.redo(); try await commands.joinPendingCommand(); try await model.flush()
    let laterRedone = try await model.captureDocument(initial.document.id)
    XCTAssertEqual(laterRedone.completeSnapshot?.text, "abc")
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Actual current/retired callback assertions failed; source and receivers retained.")
    }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }

  /// Rejected scalar/selection callbacks do not grant an edit and do not
  /// poison the next native input primitive or its canonical inverse.
  func testActualMalformedAndStaleCallbacksLeaveLaterNativeTypingAndUndoUsable() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try diagnosticRoot(), model = try await open(scratch, requiresActualKeyWindow: false)
    let initial = try XCTUnwrap(model.pagedSelectedRecord)
    let input = try XCTUnwrap(model.pagedInput), commands = try XCTUnwrap(model.pagedCommands)
    let session = try XCTUnwrap(model.pagedSession), view = try XCTUnwrap(input.activeView)
    view.insertText("A😀Z", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await commands.joinPendingCommand(); try await model.flush()
    view.setSelectedRange(NSRange(location: 4, length: 0))
    let record = try XCTUnwrap(model.pagedSelectedRecord), generation = session.generation
    let selection = try input.currentDocumentSelection(), undoCount = Optional(try commands.captureLogicalHistory().undo.count)
    let backing = view.string, selectionEpoch = try XCTUnwrap(view.inputBinding).selectionEpoch

    // UTF16 position2 is inside the actual emoji's surrogate pair. Neither
    // the primitive nor the view permission callback may accept that range.
    view.boundedStorage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "x")
    XCTAssertFalse(view.shouldChangeText(in: NSRange(location: 2, length: 0), replacementString: "x"))
    view.setSelectedRange(NSRange(location: 5, length: 0))
    input.userSelectionDidChange(from: view, previousRange: NSRange(location: 2, length: 0),
      previousGeneration: generation)
    input.notifyNativeState(from: view, edited: false)
    XCTAssertEqual(session.generation, generation); XCTAssertEqual(model.pagedSelectedRecord, record)
    XCTAssertEqual(view.string, backing); XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
    XCTAssertEqual(try input.currentDocumentSelection(), selection)
    XCTAssertEqual(view.inputBinding?.selectionEpoch, selectionEpoch)
    XCTAssertEqual(Optional(try commands.captureLogicalHistory().undo.count), undoCount)
    XCTAssertNil(view.boundedStorage.mutationFailure); XCTAssertNil(view.inputBinding?.firstRefusal)
    XCTAssertNil(input.firstRefusal); XCTAssertNil(model.errorMessage); XCTAssertNil(commands.firstFailure)

    // Exercise the real TextKit input primitive without claiming the separate
    // packaged key-window/event journey that this SDK fixture cannot supply.
    view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(session.generation, generation + 1)
    try await commands.joinPendingCommand(); try await model.flush()
    let edited = try await model.captureDocument(initial.document.id)
    XCTAssertEqual(edited.completeSnapshot?.text, "A😀Zx")
    XCTAssertEqual(Optional(try commands.captureLogicalHistory().undo.count), (undoCount ?? 0) + 1)
    let oldBinding = try XCTUnwrap(view.inputBinding), oldStorage = view.boundedStorage
    let oldContext = try XCTUnwrap(view.inputContext), oldClient = try XCTUnwrap(oldContext.client as? PagedNativeTextInputClient)
    commands.manager.undo(); try await commands.joinPendingCommand(); try await model.flush()
    let undone = try await model.captureDocument(initial.document.id)
    XCTAssertEqual(undone.completeSnapshot?.text, "A😀Z")
    let current = try XCTUnwrap(input.activeView)
    XCTAssertTrue(current === view); XCTAssertEqual(oldBinding.state, .retired)
    XCTAssertFalse(current.boundedStorage === oldStorage); XCTAssertFalse(oldClient.isRetired)
    XCTAssertTrue(current.inputContext === oldContext)
    let afterUndo = try XCTUnwrap(model.pagedSelectedRecord), afterGeneration = session.generation
    let afterSelection = try input.currentDocumentSelection()
    oldStorage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "late")
    XCTAssertThrowsError(try oldBinding.admitsInput(in: session))
    // An invalid range on the CURRENT view remains an admission refusal,
    // while this old Swift reference itself is not an earlier source handle.
    view.setSelectedRange(NSRange(location: 99, length: 0))
    XCTAssertEqual(model.pagedSelectedRecord, afterUndo); XCTAssertEqual(session.generation, afterGeneration)
    XCTAssertEqual(try input.currentDocumentSelection(), afterSelection)
    XCTAssertEqual(current.string, "A😀Z"); XCTAssertNil(current.boundedStorage.mutationFailure)
    XCTAssertNil(input.firstRefusal); XCTAssertNil(current.inputBinding?.firstRefusal)
    XCTAssertNil(model.errorMessage)
    commands.manager.redo(); try await commands.joinPendingCommand(); try await model.flush()
    let redone = try await model.captureDocument(initial.document.id)
    XCTAssertEqual(redone.completeSnapshot?.text, "A😀Zx")
    XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure); XCTAssertNil(model.errorMessage)
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Malformed/stale callback assertions failed; actual source and receivers retained.")
    }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }
  func testActualContainedNFDAndZWJCommandsAfterKnownLFDoNotAwaitPublication() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try root(), model = try await open(scratch)
    let nfd = "e\u{301}", zwj = "👩🏽‍💻"
    let source = try await writeSource(scratch, edgeText: "\n" + nfd + zwj)
    try await model.importDocuments([source], flag: CancellationFlag())
    try await focusCurrentEditor(model)
    let original = try XCTUnwrap(model.pagedSelectedRecord)
    let input = try XCTUnwrap(model.pagedInput), commands = try XCTUnwrap(model.pagedCommands)
    let edgeStart: UInt64 = 16_382, nfdStart = edgeStart + 1
    let nfdEnd = nfdStart + UInt64(nfd.utf16.count), zwjEnd = nfdEnd + UInt64(zwj.utf16.count)
    let backward = NSSelectorFromString("moveBackward:"), deleteForward = NSSelectorFromString("deleteForward:")
    let deleteBackward = NSSelectorFromString("deleteBackward:")

    // The initial real16KiB read ends in the NFD base. Its unseen mark cannot
    // become a local grapheme, even though this projection starts the document.
    let initial = try XCTUnwrap(input.activeView)
    initial.setSelectedRange(NSRange(location: Int(nfdStart), length: 0))
    XCTAssertFalse(initial.hasContainedCharacterCommand(NSSelectorFromString("moveForward:")))
    XCTAssertTrue(input.handlesDocumentCommand(NSSelectorFromString("moveForward:")))

    _ = try await commands.navigate(toUTF16: edgeStart,
      selectingUTF16: PagedNativeNavigationSelection(utf16Offset: nfdEnd, utf16Length: 0))
    try await focusCurrentEditor(model)
    let nfdView = try XCTUnwrap(input.activeView), coordinates = try input.session.documentCoordinates()
    XCTAssertEqual(coordinates.utf16Start, edgeStart, "Known LF must be observed in a nonzero-origin real projection.")
    XCTAssertFalse(input.handlesDocumentCommand(backward))
    let movementGeneration = input.session.generation
    nfdView.doCommand(by: backward)
    XCTAssertEqual(nfdView.selectedRange(), NSRange(location: 1, length: 0))
    XCTAssertEqual(input.session.generation, movementGeneration)
    nfdView.setSelectedRange(NSRange(location: 3, length: 0))
    let extend = NSSelectorFromString("moveBackwardAndModifySelection:")
    XCTAssertFalse(input.handlesDocumentCommand(extend))
    nfdView.doCommand(by: extend)
    XCTAssertEqual(nfdView.selectedRange(), NSRange(location: 1, length: 2))
    let extended = try input.currentDocumentSelection()
    XCTAssertEqual(extended.utf16Offset, nfdStart); XCTAssertEqual(extended.utf16Length, 2)
    XCTAssertFalse(extended.focusAtEnd)
    XCTAssertEqual(input.session.generation, movementGeneration)
    nfdView.setSelectedRange(NSRange(location: 1, length: 0))
    XCTAssertFalse(input.handlesDocumentCommand(deleteForward))
    let beforeNFD = input.session.generation
    nfdView.doCommand(by: deleteForward)
    // These assertions occur synchronously before any storage Task can run.
    XCTAssertEqual(input.session.generation, beforeNFD + 1)
    XCTAssertTrue(nfdView.string.hasPrefix("\n" + zwj))
    XCTAssertNil(nfdView.boundedStorage.mutationFailure); XCTAssertNil(input.firstRefusal)
    try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision.summary.bytes,
      original.document.revision.summary.bytes - UInt64(nfd.utf8.count))
    let undo = NSSelectorFromString("undo:"), item = NSMenuItem(title: "Undo", action: undo, keyEquivalent: "z")
    let window = try XCTUnwrap(Self.failedWindow)
    guard let responder = window.firstResponder, responder === input.activeView,
      try XCTUnwrap(input.activeView).validateUserInterfaceItem(item), responder.tryToPerform(undo, with: item) else {
      throw BoomError.unavailable("The actual Unicode control responder did not own Undo.")
    }
    try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, original.document.revision)

    let zwjView = try XCTUnwrap(input.activeView), restored = try input.session.documentCoordinates()
    guard zwjEnd >= restored.utf16Start else { throw BoomError.invalid("Restored Unicode source has another origin.") }
    zwjView.setSelectedRange(NSRange(location: Int(zwjEnd - restored.utf16Start), length: 0))
    XCTAssertFalse(input.handlesDocumentCommand(deleteBackward))
    let beforeZWJ = input.session.generation
    zwjView.doCommand(by: deleteBackward)
    XCTAssertEqual(input.session.generation, beforeZWJ + 1)
    XCTAssertNil(zwjView.boundedStorage.mutationFailure); XCTAssertNil(input.firstRefusal)
    try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision.summary.bytes,
      original.document.revision.summary.bytes - UInt64(zwj.utf8.count))
    let bytes = try await sourceBytes(model, atUTF16: nfdStart)
    XCTAssertEqual(Data(bytes.prefix(nfd.utf8.count)), Data(nfd.utf8))
    XCTAssertEqual(try XCTUnwrap(bytes.dropFirst(nfd.utf8.count).first), 97)
    guard let finalResponder = window.firstResponder, finalResponder === input.activeView,
      try XCTUnwrap(input.activeView).validateUserInterfaceItem(item), finalResponder.tryToPerform(undo, with: item) else {
      throw BoomError.unavailable("The actual ZWJ control responder did not own Undo.")
    }
    try await commands.joinPendingCommand(); try await model.flush()
    XCTAssertEqual(model.pagedSelectedRecord?.document.revision, original.document.revision)
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Contained Unicode assertions failed; actual source and owners retained.")
    }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }

  func testActualTruncatedRegionalIndicatorContextKeepsFullSourceMovement() async throws {
    let failures = testRun?.failureCount ?? 0
    let scratch = try root(), model = try await open(scratch)
    let source = try await writeSource(scratch, edgeText: "🇦🇧🇨🇩🇪🇫")
    try await model.importDocuments([source], flag: CancellationFlag())
    try await focusCurrentEditor(model)
    let original = try XCTUnwrap(model.pagedSelectedRecord)
    let input = try XCTUnwrap(model.pagedInput), commands = try XCTUnwrap(model.pagedCommands)
    let edgeStart: UInt64 = 16_382
    // The actual window starts at the second RI. Its local pairing differs
    // from the complete source, whose pairs are AB/CD/EF.
    _ = try await commands.navigate(toUTF16: edgeStart + 2,
      selectingUTF16: PagedNativeNavigationSelection(utf16Offset: edgeStart + 4, utf16Length: 0))
    try await focusCurrentEditor(model)
    let view = try XCTUnwrap(input.activeView), forward = NSSelectorFromString("moveForward:")
    XCTAssertEqual(try input.session.documentCoordinates().utf16Start, edgeStart + 2)
    XCTAssertFalse(view.hasContainedCharacterCommand(forward))
    XCTAssertTrue(input.handlesDocumentCommand(forward))
    view.doCommand(by: forward)
    try await commands.joinPendingCommand()
    let moved = try input.currentDocumentSelection()
    XCTAssertEqual(moved.utf16Offset, edgeStart + 8, "Full source ends the actual CD pair, not the island's BC pair.")
    XCTAssertEqual(moved.utf16Length, 0)
    XCTAssertEqual(model.pagedSelectedRecord, original)
    XCTAssertNil(input.firstRefusal)
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Actual truncated RI assertions failed; source and native owners retained.")
    }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }


  func testActualLiveCloneBackupKeepsNativeUndoScrollAndLaterSaveWhileCopyHeldThenColdRestoresSnapshot() async throws {
    let failures = testRun?.failureCount ?? 0
    let parent = try diagnosticRoot(), scratch = parent.appendingPathComponent("workspace")
    let model = try await open(scratch)
    let source = try await writeSource(parent)
    let originalHash = try await Task.detached { try ModelInstaller.hashFile(source, maxBytes: 3_145_728) }.value
    try await model.importDocuments([source], flag: CancellationFlag())
    try await focusCurrentEditor(model)
    let imported = try XCTUnwrap(model.pagedSelectedRecord)
    XCTAssertEqual(imported.document.revision.summary.bytes, 3_145_728)
    let engine = try XCTUnwrap(model.pagedEngine), session = try XCTUnwrap(model.pagedSession)
    let input = try XCTUnwrap(model.pagedInput), commands = try XCTUnwrap(model.pagedCommands)
    let viewport = try XCTUnwrap(model.pagedViewport), manager = commands.manager
    let window = try XCTUnwrap(Self.failedWindow), view = try XCTUnwrap(input.activeView)
    let context = try XCTUnwrap(view.inputContext)
    view.insertText("é🙂", replacementRange: NSRange(location: 0, length: 0))
    model.draft = "Snapshot owner draft"
    let attachmentID = UUID(), attachmentBytes = Data("Snapshot attachment bytes".utf8), vault = model.store.vault
    try await Task.detached { try vault.put(attachmentBytes, kind: .attachment, id: attachmentID) }.value
    try await commands.joinPendingCommand(); try await model.flush()
    let captured = try XCTUnwrap(model.pagedSelectedRecord)
    let capturedSelection = try input.currentDocumentSelection()
    let capturedDigest = try await engine.wholeTextSha256(captured.document.revision)
    XCTAssertEqual(captured.document.revision.summary.bytes, imported.document.revision.summary.bytes + 6)
    let backup = parent.appendingPathComponent("backup"), restoredRoot = parent.appendingPathComponent("restored")
    Self.failedExport = backup
    let hold = LiveBackupCopyHold(documentID: captured.document.id,
      entered: expectation(description: "Actual cloned pages export has written 64 KiB"))
    defer { hold.release() }
    let export = try model.exportWorkspaceBackup(to: backup, progress: { try hold.copied($0, $1, $2) })
    var exportJoined = false
    do {
      guard await XCTWaiter.fulfillment(of: [hold.entered], timeout: 10) == .completed, hold.isHeld else {
        throw BoomError.unavailable("The actual clone copy did not enter its bounded hold.")
      }
      let files = try XCTUnwrap(hold.actualFiles)
      XCTAssertEqual(files.bytes, 65_536)
      XCTAssertTrue(model.pagedEngine === engine); XCTAssertTrue(model.pagedSession === session)
      XCTAssertTrue(model.pagedInput === input); XCTAssertTrue(model.pagedViewport === viewport)
      XCTAssertTrue(model.pagedCommands === commands); XCTAssertTrue(commands.manager === manager)
      XCTAssertTrue(input.activeView === view); XCTAssertTrue(view.inputContext === context)
      XCTAssertTrue(window.firstResponder === view); XCTAssertTrue(view.isEditable)
      XCTAssertFalse(model.isBusy); XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))

      // This real subsequent file publication must complete while the clone's
      // byte-copy worker remains held. Backup cannot retain either writer lock.
      view.setSelectedRange(NSRange(location: 0, length: 0))
      view.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
      try await commands.joinPendingCommand(); try await model.flush()
      XCTAssertEqual(session.sealedGeneration, session.generation)
      XCTAssertEqual(session.sealedRootRecord.document.revision.summary.bytes, captured.document.revision.summary.bytes + 1)
      XCTAssertTrue(try XCTUnwrap(input.activeView).string.hasPrefix("Xé🙂"))
      XCTAssertTrue(hold.isHeld)
      let undoItem = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
      XCTAssertNil(undoItem.target)
      XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(try XCTUnwrap(undoItem.action), with: undoItem))
      try await commands.joinPendingCommand()
      XCTAssertTrue(try XCTUnwrap(input.activeView).string.hasPrefix("é🙂"))
      let undone = try session.captureLogicalState().source
      XCTAssertEqual(undone.summary.bytes, captured.document.revision.summary.bytes)
      let redoItem = NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
      XCTAssertNil(redoItem.target)
      XCTAssertTrue(try XCTUnwrap(window.firstResponder).tryToPerform(try XCTUnwrap(redoItem.action), with: redoItem))
      try await commands.joinPendingCommand(); try await model.flush()
      let redone = try XCTUnwrap(input.activeView)
      XCTAssertTrue(redone.string.hasPrefix("Xé🙂")); XCTAssertTrue(window.firstResponder === redone)
      XCTAssertTrue(redone.undoManager === manager)
      XCTAssertTrue(model.pagedEngine === engine); XCTAssertTrue(model.pagedSession === session)
      XCTAssertTrue(model.pagedInput === input); XCTAssertTrue(model.pagedViewport === viewport)
      XCTAssertTrue(model.pagedCommands === commands); XCTAssertTrue(commands.manager === manager)

      model.draft = "Later owner draft"
      try await Task.detached { try vault.put(Data("Later attachment bytes".utf8), kind: .attachment, id: attachmentID) }.value
      try await model.flush()
      redone.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      XCTAssertTrue(redone.hasMarkedText()); XCTAssertTrue(session.isPinned)
      let extent = try session.documentCoordinates().projectedUTF16, anchor = extent - 4
      try viewport.requestScroll(toUTF16: anchor); try await viewport.joinPresentation()
      let tail = try XCTUnwrap(viewport.visibleScrollWindow)
      XCTAssertTrue(tail.snapshot.isSame(try session.captureLogicalRead().source))
      XCTAssertLessThanOrEqual(tail.text.utf8.count, 16_384)
      XCTAssertLessThanOrEqual(tail.start.utf16, anchor)
      XCTAssertGreaterThanOrEqual(tail.start.utf16 + tail.summary.utf16, anchor)
      XCTAssertTrue(redone.hasMarkedText()); XCTAssertTrue(session.isPinned)
      XCTAssertTrue(window.firstResponder === redone); XCTAssertTrue(hold.isHeld)
      redone.unmarkText(); try await commands.joinPendingCommand(); try await model.flush()
      XCTAssertTrue(try XCTUnwrap(input.activeView).string.hasPrefix("X漢é🙂"))
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      XCTAssertNil(session.persistenceFailure); XCTAssertNil(model.errorMessage)
      hold.release()
      exportJoined = true
      let published = try await export.value
      XCTAssertEqual(published, backup)
      XCTAssertFalse(hold.didTimeOut)
    } catch {
      let original = error; hold.release()
      if !exportJoined, case .failure(let cleanup) = await export.result {
        throw BoundedWorkspaceCleanupFailure(original: original, cleanup: cleanup)
      }
      throw original
    }
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Actual live backup assertions failed; native graph and files retained.")
    }
    try await joinedClose(model)
    try await Task.detached { try FileManager.default.removeItem(at: source) }.value
    let restoredStore = try await Task.detached { try WorkspaceStore(rootOverride: restoredRoot) }.value
    try await restoredStore.restoreBackup(from: backup)
    let restored = try await open(restoredRoot)
    let restoredEngine = try XCTUnwrap(restored.pagedEngine), restoredSession = try XCTUnwrap(restored.pagedSession)
    XCTAssertFalse(restoredEngine === engine); XCTAssertNotEqual(restoredSession.sessionID, session.sessionID)
    let restoredRecord = try XCTUnwrap(restored.pagedSelectedRecord)
    XCTAssertEqual(restoredRecord, captured)
    XCTAssertEqual(try XCTUnwrap(restored.pagedInput).currentDocumentSelection(), capturedSelection)
    XCTAssertEqual(restored.draft, "Snapshot owner draft")
    let restoredAttachment = try await Task.detached { try restoredStore.vault.get(.attachment, id: attachmentID) }.value
    XCTAssertEqual(restoredAttachment, attachmentBytes)
    let restoredDigest = try await restoredEngine.wholeTextSha256(restoredRecord.document.revision)
    XCTAssertEqual(restoredDigest, capturedDigest)
    let originalRevision = try XCTUnwrap(restored.state.importedFiles?[restoredRecord.document.id]?.originalRevision)
    let restoredOriginalDigest = try await restoredEngine.wholeTextSha256(originalRevision)
    XCTAssertEqual(restoredOriginalDigest, originalHash.sha256)
    XCTAssertEqual(originalRevision.summary.bytes, UInt64(originalHash.bytes))
    XCTAssertTrue(try XCTUnwrap(restored.pagedInput?.activeView).string.hasPrefix("é🙂"))
    let restoredCommands = try XCTUnwrap(restored.pagedCommands)
    XCTAssertTrue(restoredCommands.manager.canUndo)
    let undo = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
    XCTAssertTrue(try XCTUnwrap(Self.failedWindow?.firstResponder).tryToPerform(try XCTUnwrap(undo.action), with: undo))
    try await restoredCommands.joinPendingCommand(); try await restored.flush()
    let restoredBefore = try XCTUnwrap(restored.pagedSelectedRecord)
    let restoredBeforeDigest = try await restoredEngine.wholeTextSha256(restoredBefore.document.revision)
    XCTAssertEqual(restoredBeforeDigest, originalHash.sha256)
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Actual backup cold graph/content assertions failed; restored owner/files retained.")
    }
    try await joinedClose(restored); try await removeJoinedScratch(parent)
  }

  func testActualCancelledCloneCopyCleansItsFilesAndUnrelatedFailedExportDoesNotPoisonBackupRetry() async throws {
    let failures = testRun?.failureCount ?? 0
    let parent = try diagnosticRoot(), model = try await open(parent.appendingPathComponent("workspace"),
      requiresActualKeyWindow: false)
    let source = try await writeSource(parent)
    try await model.importDocuments([source], flag: CancellationFlag()); try await model.flush()
    try await focusCurrentEditor(model, requiresActualKeyWindow: false)
    let captured = try XCTUnwrap(model.pagedSelectedRecord), engine = try XCTUnwrap(model.pagedEngine)
    let session = try XCTUnwrap(model.pagedSession), input = try XCTUnwrap(model.pagedInput)
    let commands = try XCTUnwrap(model.pagedCommands), viewport = try XCTUnwrap(model.pagedViewport)
    let refused = parent.appendingPathComponent("existing-file-export-directory")
    let sentinel = refused.appendingPathComponent("retained"), sentinelBytes = Data("Retained chosen directory".utf8)
    try await Task.detached {
      try FileManager.default.createDirectory(at: refused, withIntermediateDirectories: false)
      try sentinelBytes.write(to: sentinel)
    }.value
    let unrelated = try model.exportPagedDocument(to: refused)
    guard case .failure(let unrelatedFailure) = await unrelated.result else {
      throw BoomError.invalid("The genuine file export unexpectedly replaced its chosen directory.")
    }
    guard let refusal = unrelatedFailure as? BoomError,
      case .denied(let reason) = refusal, reason == "Export cannot replace a symlink, directory or device." else {
      throw unrelatedFailure
    }
    let unchangedSentinel = try await readSmallExport(sentinel)
    XCTAssertEqual(unchangedSentinel, sentinelBytes)
    model.dismissError()
    let backup = parent.appendingPathComponent("backup"), hold = LiveBackupCopyHold(documentID: captured.document.id,
      entered: expectation(description: "Actual backup copy entered after unrelated export refusal"))
    Self.failedExport = backup
    defer { hold.release() }
    let cancelled = try model.exportWorkspaceBackup(to: backup, progress: { try hold.copied($0, $1, $2) })
    var cancelledJoined = false
    do {
      guard await XCTWaiter.fulfillment(of: [hold.entered], timeout: 10) == .completed, hold.isHeld else {
        throw BoomError.unavailable("The actual backup was poisoned by the unrelated retained export failure.")
      }
      let files = try XCTUnwrap(hold.actualFiles)
      let clone = files.source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      let container = clone.deletingLastPathComponent()
      let stage = files.staged.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      XCTAssertEqual(clone.lastPathComponent, "Workspace"); XCTAssertTrue(stage.lastPathComponent.hasPrefix(".backup-"))
      XCTAssertTrue(FileManager.default.fileExists(atPath: clone.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
      XCTAssertTrue(model.pagedEngine === engine); XCTAssertTrue(model.pagedSession === session)
      XCTAssertTrue(model.pagedInput === input); XCTAssertTrue(model.pagedViewport === viewport)
      XCTAssertTrue(model.pagedCommands === commands); XCTAssertTrue(try XCTUnwrap(input.activeView).isEditable)
      try XCTUnwrap(input.activeView).insertText("Y", replacementRange: NSRange(location: 0, length: 0))
      try await commands.joinPendingCommand(); try await model.flush()
      let later = try XCTUnwrap(model.pagedSelectedRecord)
      XCTAssertEqual(later.document.revision.summary.bytes, captured.document.revision.summary.bytes + 1)
      XCTAssertTrue(hold.isHeld)
      model.cancelExport(to: backup); hold.release()
      cancelledJoined = true
      switch await cancelled.result {
      case .success: throw BoomError.invalid("The actual cancelled copy published instead of cancelling.")
      case .failure(let error): if !(error is CancellationError) { throw error }
      }
      XCTAssertFalse(hold.didTimeOut)
      XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: container.path))
      XCTAssertTrue(try XCTUnwrap(input.activeView).string.hasPrefix("Y"))
      XCTAssertNil(input.firstRefusal); XCTAssertNil(commands.firstFailure)
      XCTAssertNil(session.persistenceFailure); XCTAssertNil(model.errorMessage)
      let retry = try model.exportWorkspaceBackup(to: backup)
      let retried = try await retry.value
      XCTAssertEqual(retried, backup)
      let copiedRoot = try await Task.detached {
        let path = backup.appendingPathComponent("documents/" + later.document.id.uuidString.lowercased() + "/document-root.json")
        let root = try JSONDecoder().decode(PagedDocumentRootRecord.self, from: RegularFile(path, limit: 16_384).data())
        try root.validate(); return root
      }.value
      XCTAssertEqual(copiedRoot, later)
      if case .failure(let retained) = await unrelated.result {
        XCTAssertEqual((retained as NSError).domain, (unrelatedFailure as NSError).domain)
        XCTAssertEqual((retained as NSError).code, (unrelatedFailure as NSError).code)
        XCTAssertEqual(retained.localizedDescription, unrelatedFailure.localizedDescription)
      } else { XCTFail("The original unrelated failure was silently replaced.") }
      let retainedSentinel = try await readSmallExport(sentinel)
      XCTAssertEqual(retainedSentinel, sentinelBytes)
    } catch {
      let original = error; hold.release()
      if !cancelledJoined, case .failure(let cleanup) = await cancelled.result, !(cleanup is CancellationError) {
        throw BoundedWorkspaceCleanupFailure(original: original, cleanup: cleanup)
      }
      throw original
    }
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Actual backup cancellation/retry assertions failed; owner and files retained.")
    }
    try await joinedClose(model); try await removeJoinedScratch(parent)
  }


  /// Consumer component control: these supplied generation DTOs are not a
  /// Runner/GPU claim. Actual Core-admitted journals, receipt IO, Model response
  /// installation, shutdown and cold workspace reopen are exercised below.
  func testIndependentEmptyEOSDeliveryFailsOnlyItsReplyAndColdReopenKeepsCompletedPeer() async throws {
    let failures = testRun?.failureCount ?? 0
    let url = try diagnosticRoot(), store = try WorkspaceStore(rootOverride: url)
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    Self.failedModel = model
    if model.selectedChat == nil { try model.newChat() }
    let chat = try XCTUnwrap(model.selectedChat)
    let policy = try ProductCore.generationPolicy(vocabularySize: 16,
      configuration: Data(#"{"eos_token_id":1}"#.utf8), controls: [1], tokenizerEOS: 1)
    let plans = try ["Empty fixture answer", "Unicode peer answer"].map {
      try ProductCore.prompt(voice: nil, history: [], instructions: "", context: "", request: $0, routing: [])
    }
    let identities = plans.enumerated().map { row, plan in
      GenerationIdentity(kind: .consultation, operationID: UUID(), recordID: UUID(), attemptID: UUID(),
        model: "public-consumer-dto", seed: UInt64(17 + row), requestDigest: Digest.sha256(plan.rawPrompt),
        maxTokens: 4, generationPolicy: policy)
    }
    let prompts = [Array(repeating: 2, count: 12), Array(repeating: 3, count: 10)]
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let geometry = try JSONDecoder().decode(PromptCacheGeometry.self,
      from: Data(#"{"chunking":"remainder","tokenCeiling":512,"chunkStride":11}"#.utf8))
    let rows = try identities.indices.map { row in
      IndependentTextCohortOrigin.Row(operationID: identities[row].operationID,
        attemptID: identities[row].attemptID, namespace: UUID(), recordID: identities[row].recordID,
        requestDigest: identities[row].requestDigest, preparedTokenDigest: Digest.sha256(try encoder.encode(prompts[row])),
        promptTokens: prompts[row].count, cachedTokens: 0, seed: identities[row].seed, outputLimit: 4,
        samplingDigest: Digest.sha256("consumer-fixture-sampling"), cacheParentID: nil,
        cacheHistoryDigest: Digest.sha256("[]"), cacheLengths: [0], cachePadding: [0])
    }
    let cohortID = UUID()
    let origins = identities.indices.map { row in
      GenerationExecutionOrigin(schema: 1, cacheAlgorithm: "independent-text-cohort-v1",
        cachedPromptTokens: 0, cacheMissReason: "public_consumer_dto",
        independentCohort: .init(schema: 1, cohortID: cohortID, row: row, rows: rows,
          policyDigest: Digest.sha256("consumer-fixture-policy"), promptWidth: 12,
          maskDigest: Digest.sha256("consumer-fixture-mask"), cacheWidths: [0], prefill: geometry))
    }
    let texts = ["", "Café 👩🏽‍💻 peer remains complete"], tokens = [[], [4, 5]]
    let outputs = identities.indices.map { row in
      MLXGemmaRunner.Output(text: texts[row], tokenIDs: tokens[row], promptDigest: rows[row].preparedTokenDigest,
        promptTokens: prompts[row].count, outputTokens: tokens[row].count, endedByEOS: true,
        stopReason: "eos", stopTokenID: 1, firstTokenSeconds: row == 0 ? nil : 0.01,
        elapsedSeconds: 0.02, executionPriority: Task.currentPriority.rawValue, executionOrigin: origins[row])
    }
    var prepared: [(ConsultationReceipt, Result<MLXGemmaRunner.Output, Error>)] = []
    var originalJournals: [Data] = []
    for row in identities.indices {
      let identity = identities[row], output = outputs[row]
      var receipt = ConsultationReceipt(operationID: identity.operationID, seed: identity.seed, state: .pending,
        failure: nil, model: identity.model, voice: nil, plan: plans[row], sources: [],
        promptDigest: identity.requestDigest, tokenIDs: [], stopReason: "pending",
        firstTokenSeconds: nil, elapsedSeconds: 0, generationPolicy: policy)
      receipt.attemptID = identity.attemptID; receipt.responseID = identity.recordID
      try store.vault.encode(receipt, kind: .receipt, id: identity.attemptID)
      try store.vault.encode(receipt, kind: .receipt, id: identity.recordID)
      try await store.checkpoint(.init(text: output.text, tokenIDs: output.tokenIDs,
        promptDigest: output.promptDigest, promptTokens: output.promptTokens,
        firstTokenSeconds: output.firstTokenSeconds, elapsedSeconds: output.elapsedSeconds,
        executionOrigin: output.executionOrigin), identity: identity, stopReason: output.stopReason,
        stopTokenID: output.stopTokenID)
      originalJournals.append(try store.vault.get(.generationJournal, id: identity.attemptID))
      let index = try XCTUnwrap(model.state.chats.firstIndex(where: { $0.id == chat.id }))
      model.state.chats[index].messages.append(ChatMessage(id: identity.recordID, role: .assistant,
        text: "", sources: [], state: .pending, provider: identity.model, speaker: Speaker(name: "Bloom")))
      prepared.append((receipt, .success(output)))
    }
    let cancelled = CancellationFlag(); cancelled.cancel()
    do {
      try await model.finishIndependentConsultationAnswers(prepared, chatID: chat.id, authority: .readOnly,
        documentSources: [], attachments: [], flag: cancelled)
      XCTFail("Canceled shared delivery entered the consumer")
    } catch is CancellationError {}
    XCTAssertEqual(model.state.chats.first(where: { $0.id == chat.id })?.messages.suffix(2).map(\.state), [.pending, .pending])
    try await model.finishIndependentConsultationAnswers(prepared, chatID: chat.id, authority: .readOnly,
      documentSources: [], attachments: [], flag: CancellationFlag())
    let received = try XCTUnwrap(model.state.chats.first(where: { $0.id == chat.id })).messages.suffix(2)
    XCTAssertEqual(received.map(\.state), [.failed, .complete]); XCTAssertEqual(received.map(\.text), texts)
    for row in identities.indices {
      let identity = identities[row]
      let receipt = try store.vault.decode(ConsultationReceipt.self, kind: .receipt, id: identity.recordID)
      XCTAssertEqual(receipt.state, row == 0 ? .failed : .complete)
      XCTAssertEqual(receipt.stopReason, "eos"); XCTAssertEqual(receipt.stopTokenID, 1)
      XCTAssertEqual(receipt.tokenIDs, tokens[row]); XCTAssertEqual(receipt.executionOrigin, origins[row])
      XCTAssertEqual(try store.vault.get(.generationJournal, id: identity.attemptID), originalJournals[row])
    }
    XCTAssertNil(model.selectedMLXRunner)
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Independent consumer assertions failed; original journals and live Model retained.")
    }
    try await joinedClose(model)
    let reopened = try WorkspaceStore(rootOverride: url), persisted = try await reopened.loadState()
    let restored = try XCTUnwrap(persisted.chats.first(where: { $0.id == chat.id })).messages.suffix(2)
    XCTAssertEqual(restored.map(\.state), [.failed, .complete]); XCTAssertEqual(restored.map(\.text), texts)
    for row in identities.indices {
      let stored = try await reopened.generationCheckpoint(identity: identities[row])
      let journal = try XCTUnwrap(stored)
      XCTAssertEqual(journal.stopReason, "eos"); XCTAssertEqual(journal.stopTokenID, 1)
      XCTAssertEqual(journal.progress.executionOrigin, origins[row])
    }
    try await reopened.releaseExclusiveWorkspace()
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Cold independent consumer assertions failed; files retained.")
    }
    try await removeJoinedScratch(url)
  }

  func testStopDispositionsAcceptedIndependentQuestionsWithoutStartingQueuedGeneration() async throws {
    let failures = testRun?.failureCount ?? 0
    let url = try diagnosticRoot(), store = try WorkspaceStore(rootOverride: url)
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    Self.failedModel = model
    if model.selectedChat == nil { try model.newChat() }
    let chat = try XCTUnwrap(model.selectedChat), entered = expectation(description: "actual foreground entered")
    model.work("Public queue stop control") { flag in
      entered.fulfill()
      try await Task.sleep(for: .seconds(10))
      try flag.check()
      XCTFail("Stopped foreground continued")
    }
    await fulfillment(of: [entered], timeout: 5)
    try model.enqueueIndependentQuestion("First independent question", in: chat, attachments: [])
    try model.enqueueIndependentQuestion("Second independent question", in: chat, attachments: [])
    XCTAssertEqual(model.pendingConsultationCount, 2)
    model.cancel()
    XCTAssertEqual(model.pendingConsultationCount, 0)
    let messages = try XCTUnwrap(model.state.chats.first(where: { $0.id == chat.id })).messages
    XCTAssertEqual(messages.suffix(2).map(\.text), ["First independent question", "Second independent question"])
    XCTAssertEqual(messages.suffix(2).map(\.state), [.cancelled, .cancelled])
    XCTAssertNil(model.selectedMLXRunner) // this control never enters a model
    try await model.shutdown() // joins actual foreground and file writers
    Self.failedModel = nil
    let reopened = try WorkspaceStore(rootOverride: url), persisted = try await reopened.loadState()
    let saved = try XCTUnwrap(persisted.chats.first(where: { $0.id == chat.id })).messages
    XCTAssertEqual(saved.suffix(2).map(\.text), messages.suffix(2).map(\.text))
    XCTAssertEqual(saved.suffix(2).map(\.state), [.cancelled, .cancelled])
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Accepted queue disposition failed; original question/files retained.")
    }
    try await removeJoinedScratch(url)
  }

  func testShutdownRetainsEveryAcceptedQueuedQuestionAndJoinsItsOriginalForeground() async throws {
    let failures = testRun?.failureCount ?? 0
    let url = try diagnosticRoot(), store = try WorkspaceStore(rootOverride: url)
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    Self.failedModel = model
    if model.selectedChat == nil { try model.newChat() }
    let chat = try XCTUnwrap(model.selectedChat), entered = expectation(description: "actual foreground entered")
    model.work("Public queue shutdown control") { flag in
      entered.fulfill(); try await Task.sleep(for: .seconds(10)); try flag.check()
      XCTFail("Shutdown foreground continued")
    }
    await fulfillment(of: [entered], timeout: 5)
    for text in ["One 👩🏽‍💻", "Two é", "Three"] {
      try model.enqueueIndependentQuestion(text, in: chat, attachments: [])
    }
    XCTAssertEqual(model.pendingConsultationCount, 3)
    try await model.shutdown()
    Self.failedModel = nil
    XCTAssertEqual(model.pendingConsultationCount, 0); XCTAssertFalse(model.isBusy)
    XCTAssertNil(model.selectedMLXRunner)
    let reopened = try WorkspaceStore(rootOverride: url), persisted = try await reopened.loadState()
    let messages = try XCTUnwrap(persisted.chats.first(where: { $0.id == chat.id })).messages
    XCTAssertEqual(messages.suffix(3).map(\.text), ["One 👩🏽‍💻", "Two é", "Three"])
    XCTAssertEqual(messages.suffix(3).map(\.state), [.cancelled, .cancelled, .cancelled])
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Accepted queue disposition failed; original question/files retained.")
    }
    try await removeJoinedScratch(url)
  }

  func testStopBeforeActualQueuedBodyEntersRetainsAcceptedQuestionAndDoesNotRestartIt() async throws {
    let failures = testRun?.failureCount ?? 0
    let url = try diagnosticRoot(), store = try WorkspaceStore(rootOverride: url)
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    Self.failedModel = model
    if model.selectedChat == nil { try model.newChat() }
    let chat = try XCTUnwrap(model.selectedChat)
    let entered = expectation(description: "actual original foreground entered")
    let stopped = expectation(description: "actual queued foreground canceled before body")
    var release: CheckedContinuation<Void, Never>?
    model.work("Public queued entry control") { flag in
      await withCheckedContinuation { release = $0; entered.fulfill() }
      try flag.check()
    }
    let deadline = Task { @MainActor in
      do {
        try await Task.sleep(for: .seconds(10))
        let continuation = release; release = nil; continuation?.resume()
      } catch {}
    }
    defer {
      deadline.cancel()
      let continuation = release; release = nil; continuation?.resume()
    }
    await fulfillment(of: [entered], timeout: 5)
    try model.enqueueIndependentQuestion("Original queued question é🙂", in: chat, attachments: [])
    var didStop = false
    // Actual @Published entry notification runs synchronously on Main before
    // the queued foreground Task gets its first turn. No producer is faked.
    let observation = model.$isBusy.dropFirst().sink { busy in
      if busy && !didStop {
        didStop = true; model.cancel(); stopped.fulfill()
      }
    }
    let continuation = try XCTUnwrap(release); release = nil; continuation.resume()
    await fulfillment(of: [stopped], timeout: 5)
    observation.cancel(); deadline.cancel(); await deadline.value
    XCTAssertTrue(didStop); XCTAssertEqual(model.pendingConsultationCount, 0)
    try await model.shutdown()
    Self.failedModel = nil
    XCTAssertNil(model.selectedMLXRunner)
    let reopened = try WorkspaceStore(rootOverride: url), persisted = try await reopened.loadState()
    let message = try XCTUnwrap(persisted.chats.first(where: { $0.id == chat.id })?.messages.last)
    XCTAssertEqual(message.text, "Original queued question é🙂")
    XCTAssertEqual(message.state, .cancelled)
    guard (testRun?.failureCount ?? 0) == failures else {
      throw BoomError.invalid("Zero-entry queue Stop failed; original question/files retained.")
    }
    try await removeJoinedScratch(url)
  }
  func testOwnedDocumentTemporaryFileDisposalJoinsSuccessFailureAndCancellation() async throws {
    let url = try root(), model = try await open(url, requiresActualKeyWindow: false)
    for outcome in 0..<2 {
      var staged: URL?
      do {
        try await model.withTemporaryDocumentFile { path in
          staged = path
          try await detachedWork { try Data("public temporary document".utf8).write(to: path, options: .withoutOverwriting) }
          XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
          if outcome == 1 { throw BoomError.invalid("Public temporary import failure") }
        }
        XCTAssertEqual(outcome, 0)
      } catch {
        XCTAssertNotEqual(outcome, 0)
      }
      let path = try XCTUnwrap(staged)
      XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
    }
    var cancelledPath: URL?
    let entered = expectation(description: "Actual owned temporary file created")
    let task = Task { @MainActor in
      try await model.withTemporaryDocumentFile { path in
        cancelledPath = path
        try await detachedWork { try Data("public cancelled document".utf8).write(to: path, options: .withoutOverwriting) }
        entered.fulfill()
        try await Task.sleep(for: .seconds(10))
      }
    }
    await fulfillment(of: [entered], timeout: 5)
    task.cancel()
    do { try await task.value; XCTFail("Cancelled temporary operation completed") }
    catch { XCTAssertTrue(error is CancellationError) }
    let path = try XCTUnwrap(cancelledPath)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
    try await joinedClose(model); try await removeJoinedScratch(url)
  }
  func testAuthoredDocumentDoesNotRetainTemporaryImportProvenance() async throws {
    let url = try root(), model = try await open(url, requiresActualKeyWindow: false)
    let document = DocumentSnapshot(title: "Authored", text: "Public authored text é🙂")
    try await model.importAuthoredDocument(document, selecting: false, flag: CancellationFlag())
    XCTAssertNil(model.state.importedFiles?[document.id])
    let captured = try await model.captureDocument(document.id)
    XCTAssertEqual(captured.completeSnapshot?.text, document.text)
    try await joinedClose(model)
    let fresh = try WorkspaceStore(rootOverride: url), state = try await fresh.loadState()
    XCTAssertNil(state.importedFiles?[document.id])
    XCTAssertTrue(state.documents.contains { $0.id == document.id })
    try await removeJoinedScratch(url)
  }
}
