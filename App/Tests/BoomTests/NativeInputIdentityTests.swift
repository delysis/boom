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

  @MainActor private func model() async throws -> WorkspaceModel {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-input-identity-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root)
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    if model.selectedChat == nil { try model.newChat() }
    model.state.autocomplete = false
    return model
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
    window.makeKeyAndOrderFront(nil)
    XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(model.pagedInput?.activeView)))
    try await NativeCheckEvidence.replacePublicDocument(model, text: source, id: id, caret: source.utf16.count)

    do {
      try await settle(host)
      return (window, host, try XCTUnwrap(model.pagedInput?.activeView))
    } catch { window.close(); throw error }
  }

  @MainActor func testManuscriptCompositionCommitIsNotReplacedByStatusRendering() async throws {
    let model = try await model(), source = "Cafe\u{301} 👩🏽‍💻 waits."
    let (window, host, editor) = try await manuscript(model, source: source)
    defer { window.close() }
    XCTAssertTrue(window.makeFirstResponder(editor))
    editor.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
    let edits = CharacterEdits(), storage = try XCTUnwrap(editor.textStorage)
    storage.delegate = edits
    defer { storage.delegate = nil }
    editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(editor.hasMarkedText())
    XCTAssertEqual(Data(try XCTUnwrap(model.selectedDocument).text.utf8), Data(source.utf8))
    editor.unmarkText()
    XCTAssertFalse(editor.hasMarkedText())
    let committed = try XCTUnwrap(model.selectedDocument)
    XCTAssertEqual(Data(committed.text.utf8), Data((source + "に").utf8))
    let count = edits.count, nativeVersion = editor.sourceVersion, caret = editor.selectedRange()
    for index in 0..<4 { model.status = "Committed status \(index)"; try await settle(host) }
    XCTAssertEqual(edits.count, count, "A committed input-method edit must not be replaced again during rendering.")
    XCTAssertEqual(editor.sourceVersion, nativeVersion)
    XCTAssertEqual(editor.selectedRange(), caret)
    XCTAssertEqual(model.selectedDocument?.textVersion, committed.textVersion)
    XCTAssertEqual(Data(editor.string.utf8), Data(committed.text.utf8))
    let store = model.store
    try await model.shutdown()
    let restored = try await NativeCheckEvidence.readPublicDocuments(store: model.store)
    let retained = try XCTUnwrap(restored.first(where: { $0.id == committed.id }))
    XCTAssertEqual(Data(retained.text.utf8), Data(committed.text.utf8))
  }

  @MainActor func testUnmarkWithoutCompositionDoesNotPublishANewManuscript() async throws {
    let model = try await model()
    let (window, host, editor) = try await manuscript(model, source: "A public lantern.")
    defer { window.close() }
    XCTAssertFalse(editor.hasMarkedText())
    let document = try XCTUnwrap(model.selectedDocument), nativeVersion = editor.sourceVersion
    let edits = CharacterEdits(), storage = try XCTUnwrap(editor.textStorage)
    storage.delegate = edits
    defer { storage.delegate = nil }
    editor.unmarkText()
    model.status = "Unmarked status"; try await settle(host)
    XCTAssertEqual(model.selectedDocument?.textVersion, document.textVersion,
      "The native no-op must not create a document revision or schedule another source publication.")
    XCTAssertEqual(editor.sourceVersion, nativeVersion)
    XCTAssertEqual(edits.count, 0)
    try await model.shutdown()
  }

  @MainActor func testContextCacheTracksExactCanonicalFormChangesInInstructionsAndMessages() async throws {
    let model = try await model()
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
    try await model.shutdown()
  }

  @MainActor func testExternalCanonicalDraftReplacementReachesNativeComposer() async throws {
    let model = try await model()
    let original = "Café\nA lantern.", replacement = "Cafe\u{301}\nA lantern."
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
    let store = model.store
    try await model.shutdown()
    let reopened = try await WorkspaceModel(storeOverride: store, loadModels: false)
    XCTAssertEqual(Data(reopened.draft.utf8), Data(replacement.utf8),
      "The owner-bound draft must retain the exact canonical form on restart.")
    XCTAssertFalse(reopened.isBusy)
    XCTAssertTrue(reopened.selectedChat?.messages.isEmpty == true)
    try await reopened.shutdown()
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
    let model = try await model()
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
    try await model.shutdown()
  }

  @MainActor func testBusyInputCompletionDefersChangingChatDigestUntilIdleWithoutLosingNativeText() async throws {
    let model = try await model()
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
    try await model.shutdown()
  }

  @MainActor func testCompletionInvalidatesTargetAndReboundStorageWithoutRehashingUnchangedSource() async throws {
    let model = try await model()
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
    try await model.shutdown()
  }
}
