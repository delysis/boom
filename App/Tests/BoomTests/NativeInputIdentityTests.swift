import AppKit
import BoomCore
import SwiftUI
import XCTest
@testable import Boom

final class NativeInputIdentityTests: XCTestCase {
  @MainActor private final class CharacterEdits: NSObject, NSTextStorageDelegate {
    var count = 0
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
      range editedRange: NSRange, changeInLength delta: Int) {
      if editedMask.contains(.editedCharacters) { count += 1 }
    }
  }

  private struct WorkspaceCleanupFailure: Error, LocalizedError {
    let original: Error
    let cleanup: Error
    let model: WorkspaceModel // retain the actual graph if shutdown refused
    var errorDescription: String? { "\(original.localizedDescription) Shutdown: \(cleanup.localizedDescription)" }
  }

  @MainActor private func withModel<T>(store existing: WorkspaceStore? = nil,
    _ body: @MainActor (WorkspaceModel) async throws -> T) async throws -> T {
    _ = NSApplication.shared
    let store: WorkspaceStore
    if let existing { store = existing }
    else {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-input-identity-" + UUID().uuidString)
      let originalFailures = testRun?.failureCount ?? 0
      addTeardownBlock { [weak self] in
        // A failed assertion/close retains the actual public source for review.
        guard self?.testRun?.failureCount == originalFailures else { return }
        try FileManager.default.removeItem(at: root)
      }
      store = try WorkspaceStore(rootOverride: root)
      print("Actual native input identity workspace: \(root.path)")
    }
    let model: WorkspaceModel
    do { model = try await WorkspaceModel(storeOverride: store, loadModels: false) }
    catch let failure as WorkspacePagedStartupFailure {
      do { try await failure.model.shutdown() }
      catch { throw WorkspaceCleanupFailure(original: failure, cleanup: error, model: failure.model) }
      throw failure
    }
    let value: T
    do {
      if model.selectedChat == nil { try model.newChat() }
      model.state.autocomplete = false
      value = try await body(model)
    } catch {
      let original = error
      do { try await model.shutdown() }
      catch { throw WorkspaceCleanupFailure(original: original, cleanup: error, model: model) }
      throw original
    }
    // Do not retry an uncertain shutdown as part of the catch path above.
    do { try await model.shutdown() }
    catch { throw WorkspacePagedStartupFailure(original: error, model: model) }
    return value
  }

  /// Complete readback is restricted to these authored small fixtures. The
  /// real logical head is captured/frozen before its independent reader enters.
  @MainActor private func manuscriptBytes(_ session: PagedNativeSession,
    matching expected: PagedNativeLogicalReadSnapshot) async throws -> Data {
    guard expected.source.summary.bytes <= UInt64(PagedWorkingWindow.targetBytes) else {
      throw BoomError.budget("Input identity readback exceeds the bounded public fixture.")
    }
    let read = try session.captureLogicalRead()
    XCTAssertTrue(read.source.isSame(expected.source)); XCTAssertEqual(read.generation, expected.generation)
    let window = try await session.readLogicalPresentation(read, utf16Anchor: 0,
      maximumBytes: PagedWorkingWindow.targetBytes, cancellation: CancellationFlag())
    try session.admitLogicalRead(read)
    guard window.snapshot.isSame(read.source), window.start.bytes == 0,
      window.summary == read.source.summary else {
      throw BoomError.invalid("The public logical reader did not return its complete exact source.")
    }
    let bytes = Data(window.text.utf8)
    XCTAssertEqual(UInt64(bytes.count), read.source.summary.bytes)
    return bytes
  }

  @MainActor private func composer(in view: NSView) -> ChatTextView? {
    if let input = view as? ChatTextView { return input }
    return view.subviews.lazy.compactMap(composer).first
  }

  @MainActor private func settle(_ host: NSView) async throws {
    for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
  }

  @MainActor private func manuscript(_ model: WorkspaceModel, source: String) async throws
    -> (NSWindow, NSView, PagedNativeTextView) {
    try model.newDocument()
    try await model.joinWorkspaceOperation()
    let id = try XCTUnwrap(model.state.selectedDocument)
    let host = try XCTUnwrap(model.pagedViewport)
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 500, height: 400))
    window.isReleasedWhenClosed = false; window.contentView = host
    do {
      window.makeKeyAndOrderFront(nil)
      XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(model.pagedInput?.activeView)))
      try await NativeCheckEvidence.replacePublicDocument(model, text: source, id: id, caret: source.utf16.count)
      try await settle(host)
      return (window, host, try XCTUnwrap(model.pagedInput?.activeView))
    } catch { window.close(); throw error }
  }

  @MainActor func testManuscriptCompositionCommitIsNotReplacedByStatusRendering() async throws {
    let source = "Cafe\u{301} 👩🏽‍💻 waits."
    let (store, documentID, committedBytes) = try await withModel { model in
      let (window, host, editor) = try await manuscript(model, source: source)
      defer { window.close() }
      let session = try XCTUnwrap(model.pagedSession), id = try XCTUnwrap(model.selectedDocumentID)
      XCTAssertTrue(window.makeFirstResponder(editor))
      editor.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
      let original = try session.captureLogicalState(), published = session.sealedRootRecord
      let sealedGeneration = session.sealedGeneration
      let originalBytes = try await manuscriptBytes(session, matching: original)
      XCTAssertEqual(originalBytes, Data(source.utf8))
      let edits = CharacterEdits(), storage = try XCTUnwrap(editor.textStorage)
      storage.delegate = edits
      defer { storage.delegate = nil }
      editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      XCTAssertTrue(editor.hasMarkedText()); XCTAssertTrue(session.isPinned)
      let marked = try session.captureLogicalState()
      let expected = Data((source + "に").utf8)
      let markedBytes = try await manuscriptBytes(session, matching: marked)
      XCTAssertEqual(markedBytes, expected)
      XCTAssertEqual(Data(editor.string.utf8), expected)
      XCTAssertEqual(session.sealedRootRecord, published, "Marked logical input is not a published committed checkpoint.")
      XCTAssertEqual(session.sealedGeneration, sealedGeneration)
      XCTAssertFalse(marked.source.isSame(original.source)); XCTAssertGreaterThan(marked.generation, original.generation)
      editor.unmarkText()
      XCTAssertFalse(editor.hasMarkedText()); XCTAssertFalse(session.isPinned)
      let committed = try session.captureLogicalState()
      // AppKit owns unmark's actual primitives and may remove/reinsert the
      // marked bytes within this composition. Capture its completed source;
      // status rendering below must preserve that exact root/generation.
      let committedBytes = try await manuscriptBytes(session, matching: committed)
      XCTAssertEqual(committedBytes, expected)
      let count = edits.count, nativeVersion = editor.sourceVersion, caret = editor.selectedRange()
      for index in 0..<4 { model.status = "Committed status \(index)"; try await settle(host) }
      XCTAssertEqual(edits.count, count, "A committed input-method edit must not be replaced again during rendering.")
      XCTAssertEqual(editor.sourceVersion, nativeVersion); XCTAssertEqual(editor.selectedRange(), caret)
      let rendered = try session.captureLogicalState()
      XCTAssertTrue(rendered.source.isSame(committed.source)); XCTAssertEqual(rendered.generation, committed.generation)
      let renderedBytes = try await manuscriptBytes(session, matching: rendered)
      XCTAssertEqual(renderedBytes, expected)
      XCTAssertEqual(Data(editor.string.utf8), expected)
      return (model.store, id, expected)
    } // actual Model/input/Engine shutdown joins before restart
    try await withModel(store: store) { restored in
      XCTAssertEqual(restored.selectedDocumentID, documentID)
      let session = try XCTUnwrap(restored.pagedSession), read = try session.captureLogicalState()
      XCTAssertEqual(read.source.sourceRevision.documentID, documentID)
      let restoredBytes = try await manuscriptBytes(session, matching: read)
      XCTAssertEqual(restoredBytes, committedBytes)
    }
  }

  @MainActor func testUnmarkWithoutCompositionDoesNotPublishANewManuscript() async throws {
    try await withModel { model in
      let source = "A public lantern."
      let (window, host, editor) = try await manuscript(model, source: source)
      defer { window.close() }
      let session = try XCTUnwrap(model.pagedSession)
      XCTAssertFalse(editor.hasMarkedText())
      let document = try session.captureLogicalState(), published = session.sealedRootRecord
      let generation = session.sealedGeneration, nativeVersion = editor.sourceVersion
      let edits = CharacterEdits(), storage = try XCTUnwrap(editor.textStorage)
      storage.delegate = edits
      defer { storage.delegate = nil }
      editor.unmarkText()
      model.status = "Unmarked status"; try await settle(host)
      let after = try session.captureLogicalState()
      XCTAssertTrue(after.source.isSame(document.source))
      XCTAssertEqual(after.generation, document.generation,
        "The native no-op must not create a logical revision or source publication.")
      XCTAssertEqual(session.sealedRootRecord, published); XCTAssertEqual(session.sealedGeneration, generation)
      let afterBytes = try await manuscriptBytes(session, matching: after)
      XCTAssertEqual(afterBytes, Data(source.utf8))
      XCTAssertEqual(editor.sourceVersion, nativeVersion); XCTAssertEqual(edits.count, 0)
    }
  }

  @MainActor func testContextCacheTracksExactCanonicalFormChangesInInstructionsAndMessages() async throws {
    try await withModel { model in
      let index = try XCTUnwrap(model.state.chats.firstIndex { $0.id == model.state.selectedChat })
      let target = TextInputTarget(chatID: model.state.selectedChat, documentID: nil)
      let original = "Café", replacement = "Cafe\u{301}"
      XCTAssertEqual(original, replacement)
      XCTAssertNotEqual(Data(original.utf8), Data(replacement.utf8))
      let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
      for instructions in [true, false] {
        model.inputContextCache = nil
        if instructions { model.state.chats[index].instructions = original }
        else { model.state.chats[index].messages = [ChatMessage(role: .user, text: original)] }
        let before = try model.inputContextDigest(target)
        if instructions { model.state.chats[index].instructions = replacement }
        else { model.state.chats[index].messages[0].text = replacement }
        let captured = model.state.chats[index]
        let expected = Digest.sha256(Digest.sha256(try encoder.encode(captured)))
        XCTAssertNotEqual(expected, before, "The encoded context bytes changed despite canonical String equality.")
        XCTAssertEqual(try model.inputContextDigest(target), expected,
          "Context ownership must bind the current exact encoded source, not canonical value equality.")
      }
    }
  }

  @MainActor func testInputRefreshUsesOwnershipWithoutEncodingStoredHistory() async throws {
    try await withModel { model in
      let index = try XCTUnwrap(model.state.chats.firstIndex { $0.id == model.state.selectedChat })
      let target = TextInputTarget(chatID: model.state.selectedChat, documentID: nil)
      model.state.chats[index].messages = [ChatMessage(role: .user,
        text: String(repeating: "Café 👩🏽‍💻\n", count: 8192))]
      model.state.chats[index].instructions = "Café"
      model.inputContextCache = nil
      let original = try model.captureInputContext(target)
      let completion = TextInputCompletion(model: model, target: target)
      for _ in 0..<8 { completion.refresh() }
      XCTAssertNil(model.inputContextCache,
        "Creating and refreshing the native input must not encode/hash the stored chat.")
      XCTAssertTrue(completion.ghostSourcesRemainCurrent([], manuscriptID: UUID()))
      model.state.chats[index].instructions = "Cafe\u{301}"
      XCTAssertNotEqual(try model.inputContextStamp(target), original.stamp,
        "Canonical-equivalent edits still revoke the captured owner.")
      XCTAssertFalse(completion.ghostSourcesRemainCurrent([], manuscriptID: UUID()))
      completion.refresh()
      XCTAssertNil(model.inputContextCache, "A changed context still must not encode on refresh.")
      let capturedChat = try XCTUnwrap(original.chat)
      let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
      let expected = Digest.sha256(Digest.sha256(try encoder.encode(capturedChat)))
      let digest = try await detachedWork { try original.digests().context }
      XCTAssertEqual(digest, expected, "The worker must bind the exact original encoded snapshot.")
      XCTAssertNotEqual(try model.inputContextDigest(target), digest,
        "A later edit must not change the immutable worker snapshot or share its digest.")
      await completion.join()
    }
  }

  @MainActor func testExternalCanonicalDraftReplacementReachesNativeComposer() async throws {
    let original = "Café\nA lantern.", replacement = "Cafe\u{301}\nA lantern."
    let store = try await withModel { model in
      model.draft = original
      let host = NSHostingView(rootView: ChatPane(model: model))
      let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 480, height: 640))
      window.isReleasedWhenClosed = false; window.contentView = host
      defer { window.close() }
      try await settle(host)
      let input = try XCTUnwrap(composer(in: host))
      XCTAssertEqual(Data(input.string.utf8), Data(original.utf8))
      model.draft = replacement
      try await settle(host)
      XCTAssertEqual(Data(input.string.utf8), Data(replacement.utf8))
      XCTAssertEqual((input.string as NSString).range(of: "lantern"), (replacement as NSString).range(of: "lantern"))
      XCTAssertEqual(Data(try XCTUnwrap((input.completionClient as? TextInputCompletion)?.completionDocument).text.utf8),
        Data(replacement.utf8), "Completion must capture the source actually displayed by the native control.")
      return model.store
    }
    try await withModel(store: store) { reopened in
      XCTAssertEqual(Data(reopened.draft.utf8), Data(replacement.utf8),
        "The owner-bound draft must retain the exact canonical form on restart.")
      XCTAssertFalse(reopened.isBusy)
      XCTAssertTrue(reopened.selectedChat?.messages.isEmpty == true)
    }
  }

  @MainActor func testReaderCanonicalReplacementPreservesExactBytesAndOffsets() {
    _ = NSApplication.shared
    let original = "Café\n**A lantern.**", replacement = "Cafe\u{301}\n**A lantern.**"
    for presentation in [NativeText.Presentation.markdown, .literal] {
      let reader = NativeReadingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
      reader.setSource(original, presentation: presentation)
      reader.setSource(replacement, presentation: presentation)
      XCTAssertEqual(Data(reader.string.utf8), Data(replacement.utf8))
      XCTAssertEqual((reader.string as NSString).range(of: "lantern"), (replacement as NSString).range(of: "lantern"))
    }
  }

  @MainActor func testCompletionRetainsSourceSnapshotAcrossStatusAndCaretUpdatesUntilNativeEdit() async throws {
    try await withModel { model in
      let original = "Café 👩🏽‍💻 waits."
      model.draft = original
      let host = NSHostingView(rootView: ChatPane(model: model))
      let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 480, height: 640))
      window.isReleasedWhenClosed = false; window.contentView = host
      defer { window.close() }
      try await settle(host)
      let input = try XCTUnwrap(composer(in: host))
      let completion = try XCTUnwrap(input.completionClient as? TextInputCompletion)
      let initial = try XCTUnwrap(completion.completionDocument)
      let nativeVersion = input.sourceVersion
      let edits = CharacterEdits(), storage = try XCTUnwrap(input.textStorage)
      storage.delegate = edits
      defer { storage.delegate = nil }
      for index in 0..<6 { model.status = "Public status \(index)"; try await settle(host) }
      XCTAssertEqual(edits.count, 0)
      XCTAssertEqual(input.sourceVersion, nativeVersion)
      XCTAssertEqual(completion.completionDocument?.textVersion, initial.textVersion,
        "Status refresh must retain the existing source snapshot without rehashing or replacement.")
      input.setSelectedRange(NSRange(location: 0, length: 0))
      try await settle(host)
      XCTAssertEqual(completion.completionDocument?.textVersion, initial.textVersion,
        "A caret-only update invalidates a capture, not its unchanged source snapshot.")
      XCTAssertTrue(window.makeFirstResponder(input))
      input.undoManager?.removeAllActions()
      input.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
      input.insertText(" A lantern.", replacementRange: input.selectedRange())
      try await settle(host)
      let changed = try XCTUnwrap(completion.completionDocument)
      XCTAssertNotEqual(changed.textVersion, initial.textVersion)
      XCTAssertEqual(Data(changed.text.utf8), Data((original + " A lantern.").utf8))
      XCTAssertEqual(Data(model.draft.utf8), Data(changed.text.utf8))
      let editCount = edits.count, caret = input.selectedRange()
      for index in 0..<4 { model.status = "After edit \(index)"; try await settle(host) }
      XCTAssertEqual(edits.count, editCount, "Native publication must not echo a character replacement during rendering.")
      XCTAssertEqual(input.selectedRange(), caret)
      XCTAssertEqual(completion.completionDocument?.textVersion, changed.textVersion)
      XCTAssertTrue(input.undoManager?.canUndo == true)
      input.undoManager?.undo()
      try await settle(host)
      XCTAssertEqual(Data(input.string.utf8), Data(original.utf8))
      XCTAssertEqual(Data(model.draft.utf8), Data(original.utf8))
    }
  }

  @MainActor func testBusyInputCompletionDefersChangingChatDigestUntilIdleWithoutLosingNativeText() async throws {
    try await withModel { model in
      let target = TextInputTarget(chatID: model.state.selectedChat, documentID: nil)
      let input = ChatTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
      input.string = "Public draft."; input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
      model.inputContextCache = nil; model.isBusy = true
      let completion = TextInputCompletion(model: model, target: target)
      completion.view = input; input.completionClient = completion; input.documentID = completion.id
      completion.update(selection: input.selectedRange(), marked: false, target: target)
      completion.refresh()
      XCTAssertNil(model.inputContextCache, "Busy construction and native updates must not serialize the conversation for an ineligible completion.")
      model.isBusy = false; completion.refresh()
      let prior = try XCTUnwrap(model.inputContextCache)
      completion.resumeGhost(" A lantern.", documentID: completion.id, caret: input.selectedRange().location, sources: [])
      XCTAssertNotNil(completion.ghostStamp)
      model.isBusy = true
      let chat = try XCTUnwrap(model.state.chats.firstIndex { $0.id == target.chatID })
      model.state.chats[chat].messages.append(ChatMessage(role: .assistant, text: "Streaming response."))
      let changed = model.state.chats[chat].contentVersion
      XCTAssertNotEqual(changed, prior.version)
      completion.refresh()
      XCTAssertNil(completion.ghostStamp, "Busy input must still cancel its previously displayed completion.")
      input.string = "Public draft. Typed"; input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
      completion.update(selection: input.selectedRange(), marked: false, target: target)
      completion.refresh()
      XCTAssertEqual(model.inputContextCache?.version, prior.version, "Streaming/native refreshes must leave the unused conversation digest alone.")
      XCTAssertEqual(completion.completionDocument?.text, input.string)
      model.isBusy = false; completion.refresh()
      XCTAssertEqual(model.inputContextCache?.version, changed, "Idle refresh must reconcile the actual new conversation before completion becomes available.")
      XCTAssertEqual(completion.completionDocument?.text, "Public draft. Typed")
    }
  }

  @MainActor func testCompletionInvalidatesTargetAndReboundStorageWithoutRehashingUnchangedSource() async throws {
    try await withModel { model in
      let target = TextInputTarget(chatID: model.state.selectedChat, documentID: nil)
      let source = "Public Café prose."
      let input = ChatTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
      input.string = source; input.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
      let completion = TextInputCompletion(model: model, target: target)
      completion.view = input; input.completionClient = completion; input.documentID = completion.id
      completion.update(selection: input.selectedRange(), marked: false, target: target)
      let original = try XCTUnwrap(completion.completionDocument)
      completion.resumeGhost(" A lantern.", documentID: completion.id,
        caret: input.selectedRange().location, sources: [])
      XCTAssertNotNil(completion.ghostStamp)
      let instructions = TextInputTarget(chatID: target.chatID, documentID: nil, instructions: true)
      completion.update(selection: input.selectedRange(), marked: false, target: instructions)
      XCTAssertNil(completion.ghostStamp, "Changing the source owner invalidates the captured suggestion.")
      XCTAssertEqual(completion.completionDocument?.textVersion, original.textVersion,
        "Attribution changed, but the native source snapshot did not.")
      let oldNativeVersion = input.sourceVersion
      let oldStorage = try XCTUnwrap(input.textStorage)
      let layout = try XCTUnwrap(input.layoutManager)
      let storage = NSTextStorage(string: source)
      layout.replaceTextStorage(storage)
      XCTAssertTrue(input.layoutManager === layout)
      XCTAssertTrue(layout.textStorage === storage)
      XCTAssertTrue(input.textStorage === storage)
      XCTAssertFalse(input.textStorage === oldStorage)
      completion.update(selection: input.selectedRange(), marked: false, target: instructions)
      XCTAssertNotEqual(input.sourceVersion, oldNativeVersion)
      XCTAssertNotEqual(completion.completionDocument?.textVersion, original.textVersion,
        "A different native storage owns a fresh source snapshot even with equal bytes.")
      XCTAssertEqual(Data(try XCTUnwrap(completion.completionDocument).text.utf8), Data(source.utf8))
      let reboundVersion = input.sourceVersion
      oldStorage.append(NSAttributedString(string: " Detached source."))
      XCTAssertEqual(input.sourceVersion, reboundVersion, "The old storage must no longer invalidate this view.")
      storage.append(NSAttributedString(string: " A lantern."))
      completion.update(selection: input.selectedRange(), marked: false, target: instructions)
      XCTAssertNotEqual(input.sourceVersion, reboundVersion)
      XCTAssertEqual(Data(try XCTUnwrap(completion.completionDocument).text.utf8), Data((source + " A lantern.").utf8))
    }
  }
}
