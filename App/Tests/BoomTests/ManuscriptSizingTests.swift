import AppKit
import BoomCore
import CryptoKit
import SwiftUI
import XCTest
@testable import Boom

final class ManuscriptSizingTests: XCTestCase {
  @MainActor func testFullReplacementAfterUndoAndDocumentSwitchKeepsGlyphsValid() async throws {
    _ = NSApplication.shared
    let url = try XCTUnwrap(Bundle.module.url(forResource: "ManuscriptSizing", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode(WritingEvaluation.Fixture.self, from: Data(contentsOf: url))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-sizing-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    var state = WorkspaceState(); state.autocomplete = false; state.showChat = false
    state.documents = [.init(id: fixture.document.id, title: fixture.document.title)]
    state.selectedDocument = fixture.document.id
    try await store.save(state, documents: [fixture.document])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    let host = NSHostingView(rootView: ManuscriptPane(model: model))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 980, height: 846))
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    let editor = try XCTUnwrap(model.editor), manager = model.undoManager(fixture.document.id)
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
      let current = try XCTUnwrap(model.editor)
      XCTAssertEqual(current.string, liveText)
      XCTAssertEqual(model.selectedDocument?.text, liveText)
      current.replaceDocument(fixture.document.text, action: "Restore fixture")
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
    }
    try await model.shutdown()
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

  @MainActor func testUnchangedSizingReusesLayoutAndChangesStillMeasure() throws {
    let storage = NSTextStorage(), layout = Layout(), container = NSTextContainer()
    storage.addLayoutManager(layout); layout.addTextContainer(container)
    let view = MarkdownTextView(frame: .zero, textContainer: container)
    view.textContainerInset = NSSize(width: 28, height: 28)
    view.string = String(repeating: "The harbor was quiet.\n", count: 800)
    MarkdownStyle.apply(to: view)
    view.setSelectedRange(NSRange(location: 3, length: 0))
    let first = try XCTUnwrap(view.manuscriptSize(width: 480, minimumHeight: 100))
    let firstGeometry = layout.geometryChanges
    for _ in 0..<10 {
      XCTAssertEqual(view.manuscriptSize(width: 480, minimumHeight: 100), first)
    }
    XCTAssertEqual(layout.geometryChanges, firstGeometry, "Status and streaming updates must not invalidate unchanged geometry.")
    XCTAssertEqual(view.manuscriptSize(width: 480, minimumHeight: first.height + 100)?.height, first.height + 100)
    XCTAssertEqual(layout.geometryChanges, firstGeometry, "A viewport-height change needs no geometry invalidation.")
    _ = view.manuscriptSize(width: 320, minimumHeight: 100)
    XCTAssertEqual(layout.geometryChanges, firstGeometry,
      "A proposed width must not change the displayed text container.")
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "🙂 added prose\n")
    let changed = try XCTUnwrap(view.manuscriptSize(width: 320, minimumHeight: 100))
    MarkdownStyle.apply(to: view, bodyFont: NSFont.systemFont(ofSize: 24), lineSpacing: 12)
    let styled = try XCTUnwrap(view.manuscriptSize(width: 320, minimumHeight: 100))
    XCTAssertGreaterThan(styled.height, changed.height)
    XCTAssertEqual(view.string, "🙂 added prose\n" + String(repeating: "The harbor was quiet.\n", count: 800))
  }
}
