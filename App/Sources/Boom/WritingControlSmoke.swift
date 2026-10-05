import AppKit
import BoomCore
import CryptoKit
import Foundation
import SwiftUI

/// Explicit exported fixtures only. Exercises production controller/editor paths
/// without showing or activating a window, or accessing the user's Keychain.
@MainActor enum WritingControlSmoke {
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
    guard fixturePath.hasPrefix("/"), !FileManager.default.fileExists(atPath: path),
      let pack = ModelPacks.cached(.writing) else { throw BoomError.invalid("Use a new evidence directory and a cached writing pack.") }
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
      try await capture(fixture, pack: pack, evidence: evidence)
      try receipt("captured", evidence: evidence)
    } catch {
      try receipt("failed", evidence: evidence, failure: error.localizedDescription)
      throw error
    }
  }
  private static func store(_ evidence: URL) throws -> WorkspaceStore {
    try WorkspaceStore(rootOverride: evidence.appendingPathComponent("encrypted-workspace"), testKey: key)
  }
  private static func capture(_ fixture: WritingEvaluation.Fixture, pack: URL, evidence: URL) async throws {
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
    let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1440, height: 900),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    for example in fixture.examples { model.toggleWritingExample(example.id) }
    model.loadPack(pack, purpose: .writing)
    try await finish(model, evidence: evidence, phase: "loading")
    let initialEditor = try await editor(model, documentID: fixture.document.id)
    initialEditor.setSelectedRange(NSRange(location: fixture.caretUTF16, length: 0))
    model.movedCaret(fixture.caretUTF16, hasMarkedText: false)
    guard model.canExploreWriting else { throw BoomError.invalid("Explore was unavailable in the actual native editor.") }
    model.exploreWriting()
    try await finish(model, evidence: evidence, phase: "alternatives")
    guard let alternatives = model.candidates, alternatives.candidates.count == 3,
      alternatives.candidates.allSatisfy({ $0.state == .complete && !$0.text.isEmpty }),
      model.selectedDocument == fixture.document else {
      throw BoomError.invalid("Explore did not produce three completed alternatives without changing the manuscript; all attempts retained.")
    }
    try write(alternatives, to: evidence.appendingPathComponent("alternatives.json"))
    let editor = try await Self.editor(model, documentID: fixture.document.id)
    let manager = model.undoManager(fixture.document.id)
    manager.groupsByEvent = false; manager.removeAllActions(); manager.beginUndoGrouping()
    model.acceptCandidateWord(1)
    manager.endUndoGrouping()
    // Separate native commands by an event-loop turn, as actual input does.
    try await Task.sleep(for: .milliseconds(50))
    guard let partial = model.selectedDocument, partial.text != fixture.document.text, manager.canUndo,
      !model.candidateIsCurrent else { throw BoomError.invalid("Partial acceptance failed or left obsolete alternatives admissible.") }
    try write(partial, to: evidence.appendingPathComponent("partial-acceptance.json"))
    guard editor.tryToPerform(NSSelectorFromString("undo:"), with: nil) else {
      throw BoomError.invalid("The native editor did not handle its Undo action.")
    }
    try write(["model_text": model.selectedDocument?.text ?? "", "editor_text": editor.string],
      to: evidence.appendingPathComponent("undo-observation.json"))
    guard model.selectedDocument == fixture.document, editor.string == fixture.document.text else {
      throw BoomError.invalid("Native Undo did not restore the exact captured manuscript bytes.")
    }
    try write(model.selectedDocument, to: evidence.appendingPathComponent("after-undo.json"))
    let liveText = fixture.document.text + "\nA later human revision, absent from the captured request.\n"
    manager.beginUndoGrouping()
    editor.insertText(liveText, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    manager.endUndoGrouping()
    let example = fixture.examples[0]
    model.updateDocument(example.text + "\nA later example revision.\n", id: example.id, caret: model.caret)
    try await model.flush()
    guard !model.candidateIsCurrent else { throw BoomError.invalid("Changed manuscript or examples did not invalidate acceptance.") }
    model.branchCandidate(2)
    guard let branch = model.selectedDocument, branch.id != fixture.document.id,
      branch.text == (try ProductCore.branchWriting(alternatives.recipe, continuation: alternatives.candidates[2].text)),
      model.documents.first(where: { $0.id == fixture.document.id })?.text == liveText,
      model.state.manuscriptOrigins[branch.id]?.candidateID == alternatives.candidates[2].id else {
      throw BoomError.invalid("Branch did not use the captured manuscript and retain its lineage.")
    }
    try write(branch, to: evidence.appendingPathComponent("branch.json"))
    model.selectDocument(fixture.document.id)
    _ = try await Self.editor(model, documentID: fixture.document.id)
    model.replayCandidate(0)
    try await finish(model, evidence: evidence, phase: "replay")
    guard let replay = model.candidates, replay.id != alternatives.id, replay.candidates.count == 1,
      try canonical(replay.recipe) == canonical(alternatives.recipe),
      replay.candidates[0].seed == alternatives.candidates[0].seed,
      replay.candidates[0].tokenIDs == alternatives.candidates[0].tokenIDs,
      replay.candidates[0].text == alternatives.candidates[0].text,
      replay.candidates[0].state == .complete,
      model.documents.first(where: { $0.id == fixture.document.id })?.text == liveText else {
      throw BoomError.invalid("Replay changed its captured recipe, seed or output, or modified the live manuscript.")
    }
    try write(replay, to: evidence.appendingPathComponent("replay.json"))
    let captured = Capture(fixture: fixture, alternatives: alternatives, replay: replay,
      partialText: partial.text, branch: branch, documents: model.documents, origins: model.state.manuscriptOrigins)
    try write(captured, to: evidence.appendingPathComponent("capture.json"))
    try Data(contentsOf: pack.appendingPathComponent(ModelPacks.manifestName))
      .write(to: evidence.appendingPathComponent("model-manifest.json"))
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
  private static func finish(_ model: WorkspaceModel, evidence: URL, phase: String) async throws {
    let start = ContinuousClock().now
    while model.isBusy {
      guard start.duration(to: ContinuousClock().now) < .seconds(240) else { throw BoomError.unavailable("Writing diagnostic timed out during " + phase) }
      if let bundle = model.candidates { try write(bundle, to: evidence.appendingPathComponent(phase + "-latest.json")) }
      try await Task.sleep(for: .milliseconds(100))
    }
    if let bundle = model.candidates { try write(bundle, to: evidence.appendingPathComponent(phase + "-latest.json")) }
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
          journal.progress.text == candidate.text, journal.stopReason == candidate.stopReason else {
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
