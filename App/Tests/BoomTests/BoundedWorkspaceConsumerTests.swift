import AppKit
import CryptoKit
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

/// Source-authored ordinary Model/WorkspaceView controls. No fake engine,
/// WorkspaceState, durable ACK, native history or actor callback is supplied.
@MainActor final class BoundedWorkspaceConsumerTests: XCTestCase {
  private static var failedModel: WorkspaceModel?
  private static var failedWindow: NSWindow?
  private static var failedRoot: URL?
  private static var failedExport: URL?
  private let key = SymmetricKey(data: Data(repeating: 0x39, count: 32))
  private func root() throws -> URL {
    let result = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-bounded-consumer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
    Self.failedRoot = result; return result
  }
  private func open(_ root: URL) async throws -> WorkspaceModel {
    _ = NSApplication.shared
    let publicKey = key
    let store = try await Task.detached { try WorkspaceStore(rootOverride: root, testKey: publicKey) }.value
    let model: WorkspaceModel
    do { model = try await WorkspaceModel(storeOverride: store, loadModels: false, storageRoute: .boundedSQL) }
    catch let failure as WorkspacePagedStartupFailure { Self.failedModel = failure.model; throw failure.original }
    Self.failedModel = model
    XCTAssertTrue(model.usesPagedStorage)
    XCTAssertTrue(model.layout.isAuthor, "This exact control requires the actual Author product layout.")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 780),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
    Self.failedWindow = window
    window.layoutIfNeeded(); window.makeKeyAndOrderFront(nil)
    let view = try XCTUnwrap(model.pagedInput?.activeView)
    XCTAssertTrue(window.makeFirstResponder(view)); XCTAssertTrue(window.firstResponder === view)
    return model
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
  private func writeSource(_ root: URL) async throws -> URL {
    try await Task.detached {
      let url = root.appendingPathComponent("public-source.md")
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw BoomError.unavailable("Could not create the physical public source.") }
      let file = try FileHandle(forWritingTo: url)
      let block = Data((0..<8_192).map { $0 % 128 == 127 ? UInt8(10) : UInt8(97) })
      do {
        for _ in 0..<384 { try file.write(contentsOf: block) } // actual3MiB; no3MiB String/Data
        try file.synchronize(); try file.close()
      } catch { try? file.close(); throw error }
      return url
    }.value
  }

  func testActualOrdinaryLargeImportTailTypingUndoRedoAndColdHydrationPreserveExactRootsAndDraft() async throws {
    let failureCount = testRun?.failureCount ?? 0
    let scratch = try root(), model = try await open(scratch)
    let source = try await writeSource(scratch)
    try await model.importDocuments([source], flag: CancellationFlag())
    let imported = try XCTUnwrap(model.pagedSelectedRecord)
    XCTAssertEqual(imported.document.revision.summary.bytes, 3_145_728)
    XCTAssertNil(model.selectedDocument, "The real paged source is never a DocumentSnapshot/viewport substitution.")
    Self.failedWindow?.layoutIfNeeded()
    let viewport = try XCTUnwrap(model.pagedViewport)
    try viewport.requestScroll(toUTF16: imported.document.revision.summary.utf16 - 16)
    try await viewport.joinPresentation()
    let tail = try XCTUnwrap(viewport.visibleScrollWindow)
    XCTAssertEqual(tail.revision, imported.document.revision)
    XCTAssertLessThanOrEqual(tail.text.utf8.count, 16_384)
    try viewport.selectVisibleUTF16(0)
    let commands = try XCTUnwrap(model.pagedCommands)
    try await commands.joinPendingCommand()
    let view = try XCTUnwrap(model.pagedInput?.activeView)
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

  func testActualOrdinaryRenameRetiresOldClientAndTrashReceivesFullEncryptedArchiveWithoutRemovingDraft() async throws {
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
    XCTAssertEqual(renamed.document.title, "Renamed")
    XCTAssertEqual(renamed.document.revision, before.document.revision)
    XCTAssertEqual(renamed.historyPage, before.historyPage)
    XCTAssertEqual(oldView.inputBinding?.state, .retired)
    oldContext.client.insertText("late old context", replacementRange: NSRange(location: 0, length: 0))
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
    let archive = try await engine.loadWorkspaceDocumentArchiveRetaining(publisher, documentID: before.document.id)
    let exact = try XCTUnwrap(archive.value)
    XCTAssertEqual(exact.archive.retainedRecord, renamed)
    try await engine.abandonJoinedRootOutput(archive.lease)
    let owner = ComposerOwner(kind: .document, id: before.document.id)
    let draft = try await engine.loadWorkspaceDraftRetaining(publisher, owner: owner)
    XCTAssertEqual(draft.value?.header.draftOwner, owner)
    try await engine.abandonJoinedRootOutput(draft.lease)
    guard (testRun?.failureCount ?? 0) == failureCount else { throw BoomError.invalid("Actual ordinary assertions failed; owner/evidence retained.") }
    try await joinedClose(model); try await removeJoinedScratch(scratch)
  }

  func testActualEnteredSaveJoinsRenameAndShutdownAndZeroEntryCancellationKeepsWorkspaceUsable() async throws {
    let failureCount = testRun?.failureCount ?? 0
    let scratch = try root(), model = try await open(scratch)
    let engine = try XCTUnwrap(model.pagedEngine), before = try XCTUnwrap(model.pagedSelectedRecord)
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let gate = Task.detached { try await engine._rootCustodyControlBarrier(entered: entered, release: release) }
    var gateReleased = false
    do {
      try await Task.detached {
        guard entered.wait(timeout: .now() + .seconds(1)) == .success else { throw BoomError.unavailable("The actual executor gate did not enter.") }
      }.value
      model.draft = "The actual autosave must precede rename."
      // The time bound only limits this admission observation. The actual Root
      // entry proves the autosave passed its guard and yielded to its real read;
      // the later task/result joins below prove completion, never elapsed time.
      let deadline = ContinuousClock().now.advanced(by: .seconds(1))
      var observed = false
      while ContinuousClock().now < deadline {
        if engine.custodySnapshot.items.contains(where: {
          $0.phase == .admitted && !$0.producerJoined && $0.claims == [.workspace]
        }) { observed = true; break }
        await Task.yield()
      }
      guard observed else { throw BoomError.unavailable("The genuine scheduled autosave never admitted its held settings read.") }
      model.renameDocument(before.document.id, to: "After autosave")
      release.signal(); gateReleased = true
      try await gate.value
      try await model.joinWorkspaceOperation()
      XCTAssertEqual(model.pagedSelectedRecord?.document.title, "After autosave")
      XCTAssertEqual(model.pagedSelectedRecord?.document.revision, before.document.revision)
      // Both calls happen synchronously on Main before the new work task can
      // enter its body. There is no import/source/SQL outcome to cancel here.
      let unchanged = try XCTUnwrap(model.pagedSelectedRecord)
      try model.newDocument(); model.cancel()
      try await model.joinWorkspaceOperation()
      XCTAssertEqual(model.pagedSelectedRecord, unchanged)
      try await model.flush()
    } catch {
      let original = error
      if !gateReleased { release.signal(); gateReleased = true }
      do { try await gate.value } catch { throw BoundedWorkspaceCleanupFailure(original: original, cleanup: error) }
      throw original
    }

    let closingEntered = DispatchSemaphore(value: 0), closingRelease = DispatchSemaphore(value: 0)
    let closingGate = Task.detached { try await engine._rootCustodyControlBarrier(entered: closingEntered, release: closingRelease) }
    var closingReleased = false
    var closingTask: Task<Void, Error>?
    do {
      try await Task.detached {
        guard closingEntered.wait(timeout: .now() + .seconds(1)) == .success else { throw BoomError.unavailable("The actual close-order executor gate did not enter.") }
      }.value
      model.draft = "The entered save must durably finish before shutdown."
      let actualSave = try model.beginPagedWorkspaceSave()
      let deadline = ContinuousClock().now.advanced(by: .seconds(1))
      var observed = false
      while ContinuousClock().now < deadline {
        if engine.custodySnapshot.items.contains(where: {
          $0.phase == .admitted && !$0.producerJoined && $0.claims == [.workspace]
        }) { observed = true; break }
        await Task.yield()
      }
      guard observed else { throw BoomError.unavailable("The reserved save did not enter its real held read before shutdown.") }
      closingTask = Task { try await model.shutdown() }
      closingRelease.signal(); closingReleased = true
      await actualSave.value
      try await closingGate.value
      try await XCTUnwrap(closingTask).value
      XCTAssertNil(model.pagedEngine); XCTAssertNil(model.pagedViewport)
      XCTAssertTrue(engine.custodySnapshot.items.isEmpty); XCTAssertEqual(engine.custodySnapshot.jobs, 0)
    } catch {
      let original = error
      if !closingReleased { closingRelease.signal(); closingReleased = true }
      do { try await closingGate.value } catch { throw BoundedWorkspaceCleanupFailure(original: original, cleanup: error) }
      if let closingTask {
        do { try await closingTask.value } catch { throw BoundedWorkspaceCleanupFailure(original: original, cleanup: error) }
      }
      throw original
    }
    guard (testRun?.failureCount ?? 0) == failureCount else { throw BoomError.invalid("Actual ordered save/close assertions failed; owner and public source retained.") }
    Self.failedWindow?.orderOut(nil); Self.failedWindow?.close(); Self.failedWindow = nil; Self.failedModel = nil
    let reopened = try await open(scratch)
    XCTAssertEqual(reopened.pagedSelectedRecord?.document.title, "After autosave")
    XCTAssertEqual(reopened.pagedSelectedRecord?.document.revision, before.document.revision)
    XCTAssertEqual(reopened.draft, "The entered save must durably finish before shutdown.")
    guard (testRun?.failureCount ?? 0) == failureCount else { throw BoomError.invalid("Actual cold draft receiving failed; encrypted records and owner retained.") }
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
}
