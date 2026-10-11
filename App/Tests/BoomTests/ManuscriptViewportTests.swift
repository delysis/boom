import AppKit
import BoomCore
import CryptoKit
import SwiftUI
import XCTest
@testable import Boom

final class ManuscriptViewportTests: XCTestCase {
  /// Explicit public fixture only. These component observations are separate
  /// from packaged model-load, physical typing and release performance gates.
  @MainActor func testCapturedLongManuscriptScrollEditAndResize() async throws {
    guard let path = ProcessInfo.processInfo.environment["BLOOM_QUALIFICATION_EDITOR_FIXTURE"] else {
      throw XCTSkip("Enable the captured public manuscript comparison explicitly.")
    }
    let url = URL(fileURLWithPath: path)
    let bytes = try RegularFile(url, limit: 512 * 1024).data()
    let document = try JSONDecoder().decode(DocumentSnapshot.self, from: bytes)
    let fixtureHash = Digest.sha256(bytes)
    _ = NSApplication.shared
    for repetition in 0..<3 {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-viewport-" + UUID().uuidString)
      let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
      var state = WorkspaceState(); state.autocomplete = false; state.showChat = false
      state.documents = [.init(id: document.id, title: document.title)]
      state.selectedDocument = document.id
      try await store.save(state, documents: [document])
      let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
      guard model.layout.isAuthor else { throw XCTSkip("The Chat edition has no manuscript pane.") }
      let host = NSHostingView(rootView: WorkspaceView(model: model))
      let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 846))
      window.isReleasedWhenClosed = false; window.contentView = host
      for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
      let editor = try XCTUnwrap(model.editor)
      XCTAssertTrue(window.makeFirstResponder(editor)); model.isBusy = true
      let clock = ContinuousClock()
      var samples: [[String: Double]] = []
      for _ in 0..<12 {
        try await Task.sleep(for: .milliseconds(100))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let start = clock.now
        editor.insertText("x", replacementRange: editor.selectedRange())
        let inserted = clock.now
        editor.insertText("", replacementRange: NSRange(location: 0, length: 1))
        let deleted = clock.now
        host.layoutSubtreeIfNeeded()
        let end = clock.now
        samples.append(["insertion": start.duration(to: inserted).timeInterval,
          "deletion": inserted.duration(to: deleted).timeInterval,
          "layout": deleted.duration(to: end).timeInterval,
          "total": start.duration(to: end).timeInterval])
        XCTAssertEqual(editor.string, document.text)
        XCTAssertEqual(model.selectedDocument?.text, document.text)
        XCTAssertTrue(window.firstResponder === editor)
      }
      for width in [1190.0, 680.0, 980.0, 1190.0] {
        window.setContentSize(NSSize(width: width, height: 846))
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25))
        let layout = try XCTUnwrap(editor.layoutManager), container = try XCTUnwrap(editor.textContainer)
        let tail = NSRange(location: max(0, document.text.utf16.count - 20), length: min(20, document.text.utf16.count))
        layout.ensureLayout(forCharacterRange: tail)
        let glyphs = layout.glyphRange(forCharacterRange: tail, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
          .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        editor.scrollRangeToVisible(tail); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor.visibleRect.intersects(rect), "The final authored text must remain reachable at width \(width).")
        XCTAssertLessThanOrEqual(container.size.width + editor.textContainerInset.width * 2,
          max(editor.bounds.width, WorkspaceGeometry.proseMaximumWidth))
        XCTAssertEqual(editor.string, document.text)
      }
      let observation: [String: Any] = ["fixture_sha256": fixtureHash, "repetition": repetition,
        "utf16_length": document.text.utf16.count, "samples": samples,
        "scope": "Public production-view insertion, deletion and layout without models; component observations only"]
      print("EDITOR_VIEWPORT_OBSERVATION " + String(decoding: try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]), as: UTF8.self))
      window.close(); try await model.shutdown()
      try FileManager.default.removeItem(at: root)
    }
  }
}
