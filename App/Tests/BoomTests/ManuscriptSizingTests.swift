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
      manager.beginUndoGrouping()
      editor.insertText(fixture.document.text + "\nA later human revision.\n", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
      manager.endUndoGrouping()
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
      try model.newDocument()
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
      model.selectDocument(fixture.document.id)
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
      let current = try XCTUnwrap(model.editor)
      XCTAssertEqual(current.string, model.selectedDocument?.text)
      current.replaceDocument(fixture.document.text, action: "Restore fixture")
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
    }
    try await model.shutdown()
  }
  private final class Layout: NSLayoutManager {
    var geometryChanges = 0
    override func textContainerChangedGeometry(_ container: NSTextContainer) {
      geometryChanges += 1
      super.textContainerChangedGeometry(container)
    }
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
    XCTAssertEqual(layout.geometryChanges, firstGeometry, "A minimum page-height change needs no geometry invalidation.")
    _ = view.manuscriptSize(width: 320, minimumHeight: 100)
    XCTAssertGreaterThan(layout.geometryChanges, firstGeometry)
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "🙂 added prose\n")
    let changed = try XCTUnwrap(view.manuscriptSize(width: 320, minimumHeight: 100))
    MarkdownStyle.apply(to: view, bodyFont: NSFont.systemFont(ofSize: 24), lineSpacing: 12)
    let styled = try XCTUnwrap(view.manuscriptSize(width: 320, minimumHeight: 100))
    XCTAssertGreaterThan(styled.height, changed.height)
    XCTAssertEqual(view.string, "🙂 added prose\n" + String(repeating: "The harbor was quiet.\n", count: 800))
  }
}
