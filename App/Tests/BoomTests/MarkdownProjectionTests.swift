import AppKit
import XCTest
@testable import Boom

final class MarkdownProjectionTests: XCTestCase {
  private final class Edits: NSObject, NSTextStorageDelegate {
    var attributes: [NSRange] = []
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
      range editedRange: NSRange, changeInLength delta: Int) {
      if editedMask.contains(.editedAttributes) { attributes.append(editedRange) }
    }
  }
  @MainActor func testPlainTypingDoesNotRestyleUnchangedManuscriptOrLoseNativeAttributes() throws {
    let view = NSTextView(), observations = Edits()
    view.string = String(repeating: "The harbor was quiet.\n", count: 800)
    MarkdownStyle.apply(to: view)
    let storage = try XCTUnwrap(view.textStorage)
    let nativeKey = NSAttributedString.Key("public-native-attribute-fixture")
    storage.addAttribute(nativeKey, value: "preserve", range: NSRange(location: 0, length: storage.length))
    storage.delegate = observations
    storage.insert(NSAttributedString(string: "x", attributes: view.typingAttributes), at: 0)
    observations.attributes = []
    view.setSelectedRange(NSRange(location: 1, length: 0))
    MarkdownStyle.apply(to: view)
    XCTAssertTrue(observations.attributes.isEmpty, "Plain typing must not invalidate the whole manuscript's attributes.")
    XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
    XCTAssertEqual(view.string, "x" + String(repeating: "The harbor was quiet.\n", count: 800))
    XCTAssertEqual(storage.attribute(nativeKey, at: storage.length - 1, effectiveRange: nil) as? String, "preserve")
    MarkdownStyle.apply(to: view)
    XCTAssertTrue(observations.attributes.isEmpty, "Applying an unchanged projection must be a no-op.")
  }
  @MainActor func testRemovingFormattingRestoresBodyTraitsWithoutChangingUnicodeSourceOrSelection() throws {
    let view = NSTextView()
    view.string = "🙂 **bold *italic*** and `code`\n\nplain"
    MarkdownStyle.apply(to: view)
    let storage = try XCTUnwrap(view.textStorage)
    let bold = (view.string as NSString).range(of: "bold")
    let font = try XCTUnwrap(storage.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont)
    XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "🙂 plain prose\n\nplain")
    view.setSelectedRange(NSRange(location: 3, length: 0))
    MarkdownStyle.apply(to: view)
    let restored = try XCTUnwrap(storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
    XCTAssertFalse(NSFontManager.shared.traits(of: restored).contains(.boldFontMask))
    XCTAssertFalse(NSFontManager.shared.traits(of: restored).contains(.italicFontMask))
    XCTAssertEqual(view.string, "🙂 plain prose\n\nplain")
    XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
    XCTAssertNil(storage.attribute(.backgroundColor, at: 3, effectiveRange: nil))
  }
}
