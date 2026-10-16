import AppKit
import BoomCore
import SwiftUI
import XCTest
@testable import Boom

final class ManuscriptSizingTests: XCTestCase {
  @MainActor private final class WorkspaceCleanup {
    private var model: WorkspaceModel?
    private var shutdownAttempted = false
    private var shutdownFailure: Error?
    init(_ model: WorkspaceModel) { self.model = model }
    func close() async throws {
      guard !shutdownAttempted else {
        if let shutdownFailure { throw shutdownFailure }
        return
      }
      shutdownAttempted = true
      guard let model else { return }
      do { try await model.shutdown(); self.model = nil }
      catch { shutdownFailure = error; throw error }
    }
  }
  @MainActor func testFullReplacementAfterUndoAndDocumentSwitchKeepsGlyphsValid() async throws {
    _ = NSApplication.shared
    let url = try XCTUnwrap(Bundle.module.url(forResource: "ManuscriptSizing", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode(WritingEvaluation.Fixture.self, from: Data(contentsOf: url))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-sizing-" + UUID().uuidString)
    let store = try WorkspaceStore(rootOverride: root)
    var state = WorkspaceState(); state.autocomplete = false; state.showChat = false
    state.documents = [.init(id: fixture.document.id, title: fixture.document.title)]
    state.selectedDocument = fixture.document.id
    let model = try await NativeCheckEvidence.openPublicWorkspace(store: store, state: state, documents: [fixture.document])
    let cleanup = WorkspaceCleanup(model)
    let host = NSHostingView(rootView: ManuscriptPane(model: model))
    let app = NSApplication.shared
    let policy = app.activationPolicy()
    if policy != .regular { XCTAssertTrue(app.setActivationPolicy(.regular)) }
    defer { app.setActivationPolicy(policy) }
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: 0, y: 0, width: 980, height: 846))
    window.isReleasedWhenClosed = false; window.contentView = host
    let initialFailures = testRun?.failureCount ?? 0
    addTeardownBlock {
      try await cleanup.close()
      await MainActor.run { window.close() }
      if await MainActor.run(body: { self.testRun?.failureCount ?? 0 }) == initialFailures {
        try FileManager.default.removeItem(at: root)
      }
    }
    window.center(); window.showAsInvisibleNativeTestWindow(); app.activate(ignoringOtherApps: true)
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    let editor = try XCTUnwrap(model.pagedInput?.activeView), manager = try XCTUnwrap(model.pagedCommands).manager
    guard window.makeFirstResponder(editor), window.isKeyWindow,
      window.firstResponder === editor else {
      throw XCTSkip("Full-source Undo and replacement require the actual active manuscript editor; app-run acceptance covers that route.")
    }
    manager.groupsByEvent = false; manager.removeAllActions()
    for _ in 0..<3 {
      editor.setSelectedRange(NSRange(location: fixture.caretUTF16, length: 0))
      manager.beginUndoGrouping(); editor.insertText(" continuation", replacementRange: editor.selectedRange()); manager.endUndoGrouping()
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
      manager.undo()
      XCTAssertEqual(editor.string, fixture.document.text)
      let liveText = fixture.document.text + "\nA later human revision.\n"
      manager.beginUndoGrouping()
      editor.insertText(liveText, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
      manager.endUndoGrouping()
      XCTAssertEqual(editor.string, liveText)
      XCTAssertEqual(model.selectedDocument?.text, liveText,
        "A native replacement immediately after Undo must publish before a prior view snapshot can echo back.")
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
      XCTAssertEqual(editor.string, liveText)
      XCTAssertEqual(model.selectedDocument?.text, liveText)
      try model.newDocument()
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
      model.selectDocument(fixture.document.id)
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
      let current = try XCTUnwrap(model.pagedInput?.activeView)
      XCTAssertEqual(current.string, liveText)
      XCTAssertEqual(model.selectedDocument?.text, liveText)
      try await NativeCheckEvidence.replacePublicDocument(model, text: fixture.document.text, id: fixture.document.id, caret: fixture.caretUTF16)
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
    }
    try await cleanup.close()
    if (testRun?.failureCount ?? 0) == initialFailures { try FileManager.default.removeItem(at: root) }
  }
  private final class Layout: NSLayoutManager {
    var geometryChanges = 0
    var editedRanges: [NSRange] = []
    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
      range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
      editedRanges.append(newCharRange)
      super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
        changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }
    override func textContainerChangedGeometry(_ container: NSTextContainer) {
      geometryChanges += 1
      super.textContainerChangedGeometry(container)
    }
  }
  @MainActor func testSmallSourceEditsKeepUnchangedMeasurementGlyphs() throws {
    let original = String(repeating:
      "The harbor was quiet. A light moved across the water, and the keeper watched from the window.\n", count: 800)
    let source = NSTextStorage(string: original, attributes: [.font: NSFont.systemFont(ofSize: 15)])
    let layout = Layout(), measurement = NativeTextMeasurement(layout: layout)
    func height(_ value: NativeTextMeasurement) -> CGFloat {
      value.height(of: source, width: 380, insets: .zero, fragmentPadding: 5)
    }
    _ = height(measurement)
    let prefix = "🙂 New prose.\n"
    let edits: [() -> Void] = [
      { source.replaceCharacters(in: NSRange(location: 0, length: 0), with: prefix) },
      { source.replaceCharacters(in: NSRange(location: 0, length: prefix.utf16.count), with: "") },
      { source.addAttribute(.font, value: NSFont.systemFont(ofSize: 30), range: NSRange(location: 0, length: 20)) },
    ]
    for edit in edits {
      layout.editedRanges.removeAll()
      edit()
      XCTAssertEqual(height(measurement), height(NativeTextMeasurement()),
        "Incremental sizing must match a fresh native layout.")
      XCTAssertTrue(try XCTUnwrap(layout.textStorage).isEqual(to: source))
      XCTAssertFalse(layout.editedRanges.contains { $0.length >= original.utf16.count },
        "A local source edit must not replace the whole measurement snapshot: \(layout.editedRanges)")
    }
    XCTAssertEqual(source.string, original)
  }
  @MainActor func testAlternatingProposedWidthsReuseMeasuredGlyphGeometry() {
    let source = NSTextStorage(string: String(repeating:
      "The harbor was quiet. A light moved across the water, and the keeper watched from the window.\n", count: 800),
      attributes: [.font: NSFont.systemFont(ofSize: 15)])
    let layout = Layout(), measurement = NativeTextMeasurement(layout: layout)
    let narrow = measurement.height(of: source, width: 240, insets: .zero, fragmentPadding: 5)
    let wide = measurement.height(of: source, width: 760, insets: .zero, fragmentPadding: 5)
    let prepared = layout.geometryChanges
    XCTAssertGreaterThan(narrow, wide)
    for _ in 0..<6 {
      XCTAssertEqual(measurement.height(of: source, width: 240, insets: .zero, fragmentPadding: 5), narrow)
      XCTAssertEqual(measurement.height(of: source, width: 760, insets: .zero, fragmentPadding: 5), wide)
    }
    XCTAssertEqual(layout.geometryChanges, prepared,
      "Repeated SwiftUI proposals must reuse their measured heights instead of rebuilding all glyphs.")
  }

  @MainActor func testIncrementalSizingIncludesNativeParagraphAttributeFixes() throws {
    let first = "Before the keeper arrived.\n", second = "After the keeper left.\n"
    let source = NSTextStorage(string: first + second + String(repeating: "The harbor was quiet.\n", count: 80),
      attributes: [.font: NSFont.systemFont(ofSize: 15)])
    let paragraph = NSMutableParagraphStyle(); paragraph.headIndent = 24; paragraph.lineSpacing = 12
    source.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: first.utf16.count))
    let layout = Layout(), measurement = NativeTextMeasurement(layout: layout)
    func height(_ value: NativeTextMeasurement) -> CGFloat {
      value.height(of: source, width: 260, insets: NSSize(width: 28, height: 28), fragmentPadding: 5)
    }
    _ = height(measurement)
    let separator = first.utf16.count - 1
    source.replaceCharacters(in: NSRange(location: separator, length: 1), with: "🙂")
    XCTAssertEqual(height(measurement), height(NativeTextMeasurement()))
    XCTAssertTrue(try XCTUnwrap(layout.textStorage).isEqual(to: source),
      "Joining paragraphs must include attributes fixed outside the original character edit.")
    source.replaceCharacters(in: NSRange(location: separator, length: 2), with: "\n")
    XCTAssertEqual(height(measurement), height(NativeTextMeasurement()))
    XCTAssertTrue(try XCTUnwrap(layout.textStorage).isEqual(to: source))
    XCTAssertEqual(source.string, first + second + String(repeating: "The harbor was quiet.\n", count: 80))
  }

  @MainActor func testSizingInvalidatesForAttributesOpenEditsAndDifferentStorage() {
    let source = NSTextStorage(string: String(repeating: "The harbor was quiet.\n", count: 8),
      attributes: [.font: NSFont.systemFont(ofSize: 15)])
    let measurement = NativeTextMeasurement()
    func height(_ storage: NSTextStorage, width: CGFloat = 320) -> CGFloat {
      measurement.height(of: storage, width: width, insets: .zero, fragmentPadding: 5)
    }
    let original = height(source)
    source.addAttribute(.font, value: NSFont.systemFont(ofSize: 30),
      range: NSRange(location: 0, length: source.length))
    let styled = height(source)
    XCTAssertGreaterThan(styled, original, "An attribute-only edit invalidates the snapshot.")
    source.beginEditing()
    source.append(NSAttributedString(string: String(repeating: "More prose.\n", count: 12),
      attributes: [.font: NSFont.systemFont(ofSize: 30)]))
    let firstEdit = height(source)
    XCTAssertGreaterThan(firstEdit, styled)
    source.append(NSAttributedString(string: String(repeating: "Still more.\n", count: 12),
      attributes: [.font: NSFont.systemFont(ofSize: 30)]))
    let secondEdit = height(source)
    XCTAssertGreaterThan(secondEdit, firstEdit,
      "A second edit in the same transaction has not posted its notification yet.")
    source.endEditing()
    XCTAssertEqual(height(source), secondEdit)
    let other = NSTextStorage(string: "Short", attributes: [.font: NSFont.systemFont(ofSize: 15)])
    let short = height(other)
    XCTAssertLessThan(short, original)
    other.replaceCharacters(in: NSRange(location: 0, length: other.length),
      with: String(repeating: "A different source.\n", count: 20))
    XCTAssertGreaterThan(height(other), short, "The new storage must be observed too.")
    XCTAssertEqual(source.string, String(repeating: "The harbor was quiet.\n", count: 8)
      + String(repeating: "More prose.\n", count: 12) + String(repeating: "Still more.\n", count: 12),
      "Measurement must preserve the exact text of its source.")
  }

}
