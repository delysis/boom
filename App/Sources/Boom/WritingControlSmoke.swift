import AppKit
import BoomCore
import CryptoKit
import Foundation
import SwiftUI

/// Explicit exported fixtures only. Exercises production controller/editor paths
/// without showing or activating a window, or accessing the user's Keychain.
@MainActor enum WritingControlSmoke {
  private struct WordAcceptance: Encodable {
    let selected: Int
    let paragraph_required: Bool
    let leading_paragraph: Bool
    let accepted: String
    let expected_manuscript: String
  }
  private struct EscapeDismissal: Encodable {
    let dismissed_inline_continuation: Bool
    let manuscript_unchanged: Bool
    let retained_alternatives_unchanged: Bool
    let window_unshown: Bool
    let caret: Int
  }
  private struct InputShortcut: Encodable {
    struct Stamp: Encodable {
      let documentID: UUID
      let revision: String
      let caretUTF16: Int
      let epoch: UInt64
      init(_ value: GhostStamp) {
        documentID = value.documentID; revision = value.revision
        caretUTF16 = value.caretUTF16; epoch = value.epoch
      }
    }
    let key: String
    let beforeDocument: DocumentSnapshot
    let afterDocument: DocumentSnapshot
    let beforeStamp: Stamp
    let afterStamp: Stamp
    let beforeBundle: CandidateBundle
    let afterBundle: CandidateBundle
    let beforeCaret: Int
    let afterCaret: Int
    let requestActiveBefore: Bool
    let requestActiveAfter: Bool
    let windowUnshown: Bool
  }
  private struct Capture: Codable {
    let fixture: WritingEvaluation.Fixture
    let alternatives: CandidateBundle
    let replay: CandidateBundle
    let partialText: String
    let branch: DocumentSnapshot
    let documents: [DocumentSnapshot]
    let origins: [UUID: ManuscriptOrigin]
  }
  private static let key = SymmetricKey(data: Data(repeating: 0x5c, count: 32))
  private static let passphrase = "public writing control fixture passphrase"
  static func run(arguments: [String]) async throws {
    func argument(_ name: String) throws -> String {
      guard arguments.filter({ $0 == name }).count == 1,
        let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        throw BoomError.invalid("Use --writing-control-smoke capture|verify --evidence ABSOLUTE_DIRECTORY; capture also requires --fixture ABSOLUTE_JSON.")
      }
      return arguments[index + 1]
    }
    let action = try argument("--writing-control-smoke"), path = try argument("--evidence")
    guard ["capture", "verify"].contains(action), path.hasPrefix("/") else { throw BoomError.invalid("Invalid writing diagnostic action or path.") }
    let evidence = URL(fileURLWithPath: path)
    if action == "verify" { try await verify(evidence); return }
    let fixturePath = try argument("--fixture")
    let requestedPack: URL?
    if arguments.contains("--pack") {
      let packPath = try argument("--pack")
      guard packPath.hasPrefix("/") else { throw BoomError.invalid("Use an absolute writing model path.") }
      requestedPack = URL(fileURLWithPath: packPath)
    } else { requestedPack = nil }
    guard fixturePath.hasPrefix("/"), !FileManager.default.fileExists(atPath: path),
      let pack = requestedPack ?? ModelPacks.cached(.writing) else { throw BoomError.invalid("Use a new evidence directory and a cached writing pack.") }
    let bytes = try AttachmentProcessor.readGranted(URL(fileURLWithPath: fixturePath))
    guard bytes.count <= 4_194_304 else { throw BoomError.budget("Writing fixture exceeds 4 MiB.") }
    let fixture = try JSONDecoder().decode(WritingEvaluation.Fixture.self, from: bytes)
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try bytes.write(to: evidence.appendingPathComponent("fixture.json"))
    try receipt("running", evidence: evidence)
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + .seconds(300))
    watchdog.setEventHandler {
      fputs("Writing diagnostic exceeded its global deadline; incomplete evidence retained.\n", stderr)
      exit(2)
    }
    watchdog.resume()
    defer { watchdog.cancel() }
    do {
      try await capture(fixture, pack: pack, evidence: evidence, record: arguments.contains("--record-demonstration"),
        requireParagraph: arguments.contains("--require-paragraph-continuation"))
      try receipt("captured", evidence: evidence)
    } catch {
      try receipt("failed", evidence: evidence, failure: error.localizedDescription)
      throw error
    }
  }
  private static func store(_ evidence: URL) throws -> WorkspaceStore {
    try WorkspaceStore(rootOverride: evidence.appendingPathComponent("encrypted-workspace"), testKey: key)
  }
  private static func capture(_ fixture: WritingEvaluation.Fixture, pack: URL, evidence: URL, record: Bool,
    requireParagraph: Bool) async throws {
    let admission = try await detachedWork { try ModelPacks.admission(pack, purpose: .writing) }
    let manifest = try await detachedWork { try ModelPacks.evidenceManifest(admission, purpose: .writing) }
    try manifest.write(to: evidence.appendingPathComponent("model-manifest.json"), options: .atomic)
    _ = try ProductCore.authoredPrefix(fixture.document, caret: fixture.caretUTF16)
    let store = try store(evidence)
    var state = WorkspaceState(); state.autocomplete = false
    let documents = [fixture.document] + fixture.examples
    guard !fixture.examples.isEmpty, fixture.examples.count <= 32,
      Set(documents.map(\.id)).count == documents.count else { throw BoomError.invalid("Use distinct manuscript and example identities.") }
    state.documents = documents.map { DocumentIndex(id: $0.id, title: $0.title) }
    state.selectedDocument = fixture.document.id; state.showChat = false
    try await store.save(state, documents: documents)
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    guard model.layout.isAuthor else { throw BoomError.unavailable("Use the author edition for this writing diagnostic.") }
    let host = NSHostingView(rootView: WorkspaceView(model: model))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -5000, y: -5000, width: 1440, height: 900))
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    let recorder = record ? try NativeDemoRecorder(view: host, evidence: evidence) : nil
    defer { recorder?.cancel() }
    try await recorder?.checkpoint("Authored manuscript")
    for example in fixture.examples {
      model.toggleWritingExample(example.id)
      try await recorder?.checkpoint("Selected literary example: " + example.title)
    }
    model.loadPack(pack, purpose: .writing)
    try await finish(model, evidence: evidence, phase: "loading", recorder: recorder)
    let initialEditor = try await editor(model, documentID: fixture.document.id)
    initialEditor.setSelectedRange(NSRange(location: fixture.caretUTF16, length: 0))
    initialEditor.scrollRangeToVisible(initialEditor.selectedRange())
    model.movedCaret(fixture.caretUTF16, hasMarkedText: false)
    guard model.canExploreWriting else { throw BoomError.invalid("Explore was unavailable in the actual native editor.") }
    try await recorder?.checkpoint("Explore at captured caret")
    model.exploreWriting()
    try await finish(model, evidence: evidence, phase: "alternatives", recorder: recorder)
    guard let alternatives = model.candidates, alternatives.candidates.count == 3,
      alternatives.selected == 1,
      alternatives.candidates.allSatisfy({ $0.state == .complete && !$0.text.isEmpty }),
      Set(alternatives.candidates.map(\.text)).count == 3,
      model.selectedDocument == fixture.document else {
      throw BoomError.invalid("Explore did not produce three completed alternatives without changing the manuscript; all attempts retained.")
    }
    try await recorder?.checkpoint("Three shared-prefill alternatives")
    try write(alternatives, to: evidence.appendingPathComponent("alternatives.json"))
    guard let dismissStamp = model.ghostStamp else {
      throw BoomError.invalid("The completed continuation has no captured insertion point.")
    }
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
    guard let escape else { throw BoomError.invalid("Cannot construct the public Escape event.") }
    initialEditor.keyDown(with: escape)
    guard model.ghostStamp == nil, model.ghostText.isEmpty,
      model.selectedDocument == fixture.document, initialEditor.string == fixture.document.text,
      initialEditor.selectedRange().location == dismissStamp.caretUTF16,
      try canonical(model.candidates) == canonical(Optional(alternatives)), !window.isVisible else {
      throw BoomError.invalid("Escape changed the manuscript, insertion point or retained alternatives.")
    }
    try write(EscapeDismissal(dismissed_inline_continuation: true, manuscript_unchanged: true,
      retained_alternatives_unchanged: true, window_unshown: true, caret: dismissStamp.caretUTF16),
      to: evidence.appendingPathComponent("escape-dismissal.json"))
    try await recorder?.checkpoint("Escape dismissed inline continuation")
    model.selectCandidate(1)
    guard model.canReplayCandidate(1) else { throw BoomError.invalid("The captured continuation is unexpectedly unavailable for replay.") }
    guard var legacyObject = try ProductCore.object(alternatives) as? [String: Any],
      var legacyRecipe = legacyObject["recipe"] as? [String: Any],
      var legacyPolicy = legacyRecipe["generationPolicy"] as? [String: Any] else {
      throw BoomError.invalid("The captured continuation has no model settings.")
    }
    legacyPolicy.removeValue(forKey: "prefill")
    legacyRecipe["generationPolicy"] = legacyPolicy; legacyObject["recipe"] = legacyRecipe
    model.candidates = try JSONDecoder().decode(CandidateBundle.self,
      from: JSONSerialization.data(withJSONObject: legacyObject))
    let unrecordedAvailable = model.canReplayCandidate(1)
    model.candidates = alternatives
    guard !unrecordedAvailable, model.canReplayCandidate(1), model.selectedDocument == fixture.document else {
      throw BoomError.invalid("Replay availability did not preserve the original manuscript and captured alternatives.")
    }
    try write(["captured_settings_available": true, "unrecorded_geometry_available": false,
      "captured_settings_restored": true], to: evidence.appendingPathComponent("replay-availability.json"))
    model.setAutocomplete(true)
    let editor = try await Self.editor(model, documentID: fixture.document.id)
    let paragraphIndex = alternatives.candidates.firstIndex { $0.text.hasPrefix("\n\n") }
    guard !requireParagraph || paragraphIndex != nil else {
      throw BoomError.invalid("No captured alternative begins with a paragraph break; that acceptance case remains untested.")
    }
    let wordIndex = requireParagraph ? (paragraphIndex ?? 1) : 1
    model.selectCandidate(wordIndex)
    let word = CompletionNavigation.nextChunk(alternatives.candidates[wordIndex].text).accepted
    let expectedPartial = try ProductCore.branchWriting(alternatives.recipe, continuation: word)
    try write(WordAcceptance(selected: wordIndex, paragraph_required: requireParagraph,
      leading_paragraph: alternatives.candidates[wordIndex].text.hasPrefix("\n\n"),
      accepted: word, expected_manuscript: expectedPartial),
      to: evidence.appendingPathComponent("word-acceptance-input.json"))
    let manager = model.undoManager(fixture.document.id)
    manager.groupsByEvent = false; manager.removeAllActions(); manager.beginUndoGrouping()
    model.acceptCandidateWord(wordIndex)
    manager.endUndoGrouping()
    try await recorder?.checkpoint("Accepted next word")
    // Separate native commands by an event-loop turn, as actual input does.
    try await Task.sleep(for: .milliseconds(50))
    guard let partial = model.selectedDocument, partial.text == expectedPartial, partial.text != fixture.document.text, manager.canUndo,
      !model.candidateIsCurrent else { throw BoomError.invalid("Partial acceptance failed or left obsolete alternatives admissible.") }
    try write(partial, to: evidence.appendingPathComponent("partial-acceptance.json"))
    // Keep suggestions enabled while the captured choices become stale. The
    // open tray must retain all three, so the writer can still branch from them.
    let retainedIDs = model.state.candidateIDs
    try await Task.sleep(for: .seconds(2))
    guard model.showingCandidates, let retained = model.candidates, retained.id == alternatives.id,
      retained.selected == wordIndex, try canonical(retained.recipe) == canonical(alternatives.recipe),
      try canonical(retained.candidates) == canonical(alternatives.candidates), model.state.candidateIDs == retainedIDs,
      model.selectedDocument == partial else {
      throw BoomError.invalid("Autocomplete replaced the visible captured choices after partial acceptance.")
    }
    try write(["bundle": retained.id.uuidString, "choices": String(retained.candidates.count),
      "selected": String(retained.selected), "autocomplete_enabled": String(model.state.autocomplete)],
      to: evidence.appendingPathComponent("visible-choice-retention.json"))
    model.setAutocomplete(false)
    guard editor.tryToPerform(NSSelectorFromString("undo:"), with: nil) else {
      throw BoomError.invalid("The native editor did not handle its Undo action.")
    }
    try write(["model_text": model.selectedDocument?.text ?? "", "editor_text": editor.string],
      to: evidence.appendingPathComponent("undo-observation.json"))
    guard model.selectedDocument == fixture.document, editor.string == fixture.document.text else {
      throw BoomError.invalid("Native Undo did not restore the exact captured manuscript bytes.")
    }
    try await recorder?.checkpoint("Native Undo restored exact manuscript")
    try write(model.selectedDocument, to: evidence.appendingPathComponent("after-undo.json"))
    model.selectCandidate(0)
    try await recorder?.checkpoint("Selected first alternative for full acceptance")
    manager.beginUndoGrouping()
    model.acceptCandidate(0)
    manager.endUndoGrouping()
    try await Task.sleep(for: .milliseconds(50))
    let prefix = try ProductCore.authoredPrefix(fixture.document, caret: fixture.caretUTF16)
    let fullText = prefix + alternatives.candidates[0].text + fixture.document.text.dropFirst(prefix.count)
    guard model.selectedDocument?.text == fullText, editor.string == fullText, manager.canUndo else {
      throw BoomError.invalid("Full acceptance changed text outside the captured insertion point.")
    }
    try write(model.selectedDocument, to: evidence.appendingPathComponent("full-acceptance.json"))
    try await recorder?.checkpoint("Accepted full continuation")
    guard editor.tryToPerform(NSSelectorFromString("undo:"), with: nil) else {
      throw BoomError.invalid("The native editor did not undo full acceptance.")
    }
    guard model.selectedDocument == fixture.document, editor.string == fixture.document.text else {
      throw BoomError.invalid("Undo of full acceptance changed the captured manuscript.")
    }
    try await recorder?.checkpoint("Undo restored manuscript after full acceptance")
    let liveText = fixture.document.text + "\nA later human revision, absent from the captured request.\n"
    manager.beginUndoGrouping()
    editor.insertText(liveText, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    manager.endUndoGrouping()
    let example = fixture.examples[0]
    model.updateDocument(example.text + "\nA later example revision.\n", id: example.id, caret: model.caret)
    try await model.flush()
    guard !model.candidateIsCurrent else { throw BoomError.invalid("Changed manuscript or examples did not invalidate acceptance.") }
    model.dismissCandidates()
    model.reviewContinuation(alternatives.id)
    try await finish(model, evidence: evidence, phase: "reopen-before-branch", recorder: recorder)
    model.selectCandidate(2)
    try await recorder?.checkpoint("Selected third captured alternative for branching")
    let branchReady: [String: String] = [
      "busy": String(model.isBusy), "markedText": String(model.editor?.hasMarkedText() ?? false),
      "candidateState": model.candidates?.candidates[2].state.rawValue ?? "missing",
      "document": model.state.selectedDocument?.uuidString ?? "missing",
      "parentDigest": model.documents.first(where: { $0.id == fixture.document.id })?.revision ?? "missing",
      "expectedParentDigest": Digest.sha256(liveText),
    ]
    model.branchCandidate(2)
    try write(branchReady.merging([
      "resultDocument": model.state.selectedDocument?.uuidString ?? "missing",
      "resultDigest": model.selectedDocument?.revision ?? "missing",
      "expectedDigest": Digest.sha256(try ProductCore.branchWriting(alternatives.recipe, continuation: alternatives.candidates[2].text)),
      "resultCandidate": model.state.selectedDocument.flatMap { model.state.manuscriptOrigins[$0]?.candidateID.uuidString } ?? "missing",
      "expectedCandidate": alternatives.candidates[2].id.uuidString,
      "failure": model.errorMessage ?? "none",
    ]) { _, result in result }, to: evidence.appendingPathComponent("branch-observation.json"))
    guard let branch = model.selectedDocument, branch.id != fixture.document.id,
      branch.text == (try ProductCore.branchWriting(alternatives.recipe, continuation: alternatives.candidates[2].text)),
      model.documents.first(where: { $0.id == fixture.document.id })?.text == liveText,
      model.state.manuscriptOrigins[branch.id]?.candidateID == alternatives.candidates[2].id else {
      throw BoomError.invalid("Branch did not use the captured manuscript and retain its lineage.")
    }
    try await recorder?.checkpoint("Branch from captured continuation")
    try write(branch, to: evidence.appendingPathComponent("branch.json"))
    model.selectDocument(fixture.document.id)
    _ = try await Self.editor(model, documentID: fixture.document.id)
    guard model.candidates == nil, !model.showingCandidates else {
      throw BoomError.invalid("A document switch retained foreign continuations.")
    }
    model.reviewContinuation(alternatives.id)
    try await finish(model, evidence: evidence, phase: "reopen-before-replay", recorder: recorder)
    model.selectCandidate(1)
    try await recorder?.checkpoint("Selected second captured alternative for replay")
    model.replayCandidate(1)
    try await finish(model, evidence: evidence, phase: "replay", recorder: recorder)
    guard let replay = model.candidates, replay.id != alternatives.id, replay.candidates.count == 3, replay.selected == 1,
      try canonical(replay.recipe) == canonical(alternatives.recipe),
      zip(replay.candidates, alternatives.candidates).allSatisfy({ again, original in
        again.seed == original.seed && again.tokenIDs == original.tokenIDs
          && again.text == original.text && again.state == .complete && again.batch == original.batch
      }),
      model.documents.first(where: { $0.id == fixture.document.id })?.text == liveText else {
      throw BoomError.invalid("Replay changed its captured recipe, seed or output, or modified the live manuscript.")
    }
    try await recorder?.checkpoint("Captured seeds replayed after later human edits")
    try await recorder?.finish()
    try write(replay, to: evidence.appendingPathComponent("replay.json"))
    let captured = Capture(fixture: fixture, alternatives: alternatives, replay: replay,
      partialText: partial.text, branch: branch, documents: model.documents, origins: model.state.manuscriptOrigins)
    try write(captured, to: evidence.appendingPathComponent("capture.json"))
    for dark in [true, false] {
      for width in [1440, 760] { try await render(model, width: width, dark: dark, evidence: evidence) }
    }
    try await model.shutdown()
    try await store.exportBackup(passphrase: passphrase, to: evidence.appendingPathComponent("complete.bloombackup"))
    print("Real-model alternatives, native partial acceptance/Undo, captured branching and replay passed.")
  }
  private static func render(_ model: WorkspaceModel, width: Int, dark: Bool, evidence: URL) async throws {
    model.fitPanes(to: CGFloat(width))
    let view = NSHostingView(rootView: WorkspaceView(model: model).environment(\.colorScheme, dark ? .dark : .light))
    let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: 900),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = view
    try await Task.sleep(for: .milliseconds(100))
    view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw BoomError.invalid("Native body render was unavailable.") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw BoomError.invalid("Native body render could not be encoded.") }
    try png.write(to: evidence.appendingPathComponent("body-\(width)-\(dark ? "dark" : "light").png"), options: .atomic)
  }
  private static func editor(_ model: WorkspaceModel, documentID: UUID) async throws -> MarkdownTextView {
    let start = ContinuousClock().now
    while start.duration(to: ContinuousClock().now) < .seconds(5) {
      if let editor = model.editor, editor.documentID == documentID { return editor }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw BoomError.invalid("The production native manuscript editor did not attach.")
  }
  private static func finish(_ model: WorkspaceModel, evidence: URL, phase: String, recorder: NativeDemoRecorder?) async throws {
    let start = ContinuousClock().now
    var selectedDuringGeneration = false
    var clickedDuringGeneration = false
    var shortcutDuringGeneration = false
    while model.isBusy {
      if phase == "alternatives", let editor = model.editor, let window = editor.window {
        guard editor.isEditable, window.canBecomeKey, window.makeFirstResponder(editor),
          window.firstResponder === editor else { throw BoomError.invalid("Generation took keyboard focus away from the native manuscript editor.") }
      }
      if phase == "alternatives", !selectedDuringGeneration, model.candidates?.candidates.count == 3 {
        model.selectCandidate(1); selectedDuringGeneration = true
      }
      if phase == "alternatives", !clickedDuringGeneration, let stamp = model.ghostStamp,
        let editor = model.editor, let document = model.selectedDocument {
        let range = editor.selectedRange()
        guard range.length == 0 else { throw BoomError.invalid("The public writing fixture lost its insertion point.") }
        let point = try NativeCaretProbe.point(at: range.location, in: editor)
        let observation = try NativeCaretProbe.click(point, in: editor)
        try write(observation, to: evidence.appendingPathComponent("caret-during-generation.json"))
        guard editor.selectedRange() == range, model.ghostStamp == stamp,
          model.selectedDocument == document else {
          throw BoomError.invalid("Refocusing the same caret changed the public manuscript or invalidated its real-model continuation.")
        }
        clickedDuringGeneration = true
        try await recorder?.checkpoint("Native click preserves the captured caret during generation")
      }
      if phase == "alternatives", !shortcutDuringGeneration, model.isBusy,
        let stamp = model.ghostStamp, let bundle = model.candidates,
        let editor = model.editor, let window = editor.window, let document = model.selectedDocument {
        let range = editor.selectedRange()
        guard range.length == 0, let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero,
          modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: "\u{0}",
          charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else {
          throw BoomError.invalid("Cannot deliver the public native input shortcut.")
        }
        editor.keyDown(with: shortcut)
        guard let afterStamp = model.ghostStamp, let afterBundle = model.candidates,
          let afterDocument = model.selectedDocument else {
          throw BoomError.invalid("The native input shortcut discarded a real-model capture.")
        }
        try write(InputShortcut(key: "control-space", beforeDocument: document, afterDocument: afterDocument,
          beforeStamp: .init(stamp), afterStamp: .init(afterStamp), beforeBundle: bundle, afterBundle: afterBundle,
          beforeCaret: range.location, afterCaret: editor.selectedRange().location,
          requestActiveBefore: true, requestActiveAfter: model.isBusy, windowUnshown: !window.isVisible),
          to: evidence.appendingPathComponent("input-shortcut-during-generation.json"))
        guard editor.selectedRange() == range, afterStamp == stamp, afterDocument == document,
          try canonical(afterBundle) == canonical(bundle), model.isBusy, !window.isVisible else {
          throw BoomError.invalid("The native input shortcut changed or cancelled its captured generation.")
        }
        shortcutDuringGeneration = true
        try await recorder?.checkpoint("Native input shortcut preserves captured generation")
      }
      guard start.duration(to: ContinuousClock().now) < .seconds(240) else { throw BoomError.unavailable("Writing diagnostic timed out during " + phase) }
      if let bundle = model.candidates { try write(bundle, to: evidence.appendingPathComponent(phase + "-latest.json")) }
      try recorder?.frame(phase)
      try await Task.sleep(for: .milliseconds(100))
    }
    if let bundle = model.candidates { try write(bundle, to: evidence.appendingPathComponent(phase + "-latest.json")) }
    if phase == "alternatives", !clickedDuringGeneration {
      throw BoomError.invalid("The real-model writing fixture never exercised its native caret click.")
    }
    if phase == "alternatives", !shortcutDuringGeneration {
      throw BoomError.invalid("The real-model writing fixture never exercised its native input shortcut.")
    }
    if let error = model.errorMessage ?? model.writingIssue { throw BoomError.invalid(error) }
  }
  private static func verify(_ evidence: URL) async throws {
    let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: evidence.appendingPathComponent("capture.json")))
    let source = try store(evidence)
    try await verify(source, capture: capture)
    let restored = try WorkspaceStore(rootOverride: evidence.appendingPathComponent("restored-workspace"),
      testKey: SymmetricKey(data: Data(repeating: 0x5d, count: 32)))
    _ = try await restored.restoreBackup(passphrase: passphrase, from: evidence.appendingPathComponent("complete.bloombackup"))
    try await verify(restored, capture: capture)
    try receipt("passed", evidence: evidence)
    print("Separate-process writing relaunch and complete passphrase restore preserved every manuscript, candidate and journal.")
  }
  private static func verify(_ store: WorkspaceStore, capture: Capture) async throws {
    let (state, documents) = try await store.load().get()
    guard documents == capture.documents, Set(state.manuscriptOrigins.keys) == Set(capture.origins.keys),
      try capture.origins.allSatisfy({ try canonical(state.manuscriptOrigins[$0.key]) == canonical(Optional($0.value)) }) else {
      throw BoomError.invalid("Manuscripts or branch lineage changed across relaunch/restore.")
    }
    for bundle in [capture.alternatives, capture.replay] {
      let saved = try store.vault.decode(CandidateBundle.self, kind: .candidate, id: bundle.id)
      guard state.candidateIDs.contains(bundle.id), try canonical(saved) == canonical(bundle) else { throw BoomError.invalid("Captured candidate bundle changed.") }
      for candidate in saved.candidates {
        guard let journal = try await store.writingCheckpoint(bundle: saved, candidate: candidate),
          journal.identity.seed == candidate.seed, journal.progress.tokenIDs == candidate.tokenIDs,
          journal.progress.text == candidate.text, journal.stopReason == candidate.stopReason,
          journal.stopTokenID == candidate.stopTokenID,
          journal.identity.batch == candidate.batch,
          journal.identity.generationPolicy == bundle.recipe.generationPolicy else {
          throw BoomError.invalid("Generation journal disagreed with the retained candidate.")
        }
      }
    }
  }
  private static func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
  private static func write<T: Encodable>(_ value: T, to url: URL) throws {
    try canonical(value).write(to: url, options: .atomic)
  }
  private static func receipt(_ status: String, evidence: URL, failure: String? = nil) throws {
    var result: [String: Any] = ["status": status, "executable": CommandLine.arguments[0],
      "source_inventory_sha256": Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") ?? "unavailable",
      "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
      "interactive_ui_qualified": false, "real_keychain_qualified": false, "target_32_gb_qualified": false,
      "writing_quality_qualified": false, "network_denial_must_be_verified_by_driver": true]
    if let failure { result["failure"] = failure }
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: evidence.appendingPathComponent(status == "passed" ? "verification.json" : "diagnostic.json"), options: .atomic)
  }
}
