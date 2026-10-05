import XCTest

@testable import BoomCore

final class BoundaryTests: XCTestCase {
  func testMultilineInlineCodeCannotImportReferences() throws {
    XCTAssertEqual(
      try ReferenceParser.wiki("`code\n[[Hidden]]\n` [[Visible]]").map(\.title), ["Visible"])
    XCTAssertTrue(try ReferenceParser.voices("`code\n@hidden\n`").isEmpty)
  }
  func testBackslashInInlineCodeDoesNotHideTheClosingDelimiter() throws {
    XCTAssertEqual(try ReferenceParser.wiki("`code\\` [[Visible]]").map(\.title), ["Visible"])
  }
  func testCompletionStopsBeforeSecondParagraph() {
    XCTAssertEqual(
      GemmaPrompt.visibleCompletion("100 feet tall.\n\n[[Voice]]"), "100 feet tall.")
    XCTAssertEqual(GemmaPrompt.visibleCompletion("<3 forever"), "<3 forever")
  }
  func testDocumentAttachmentLinksAreStableAndDeduplicated() throws {
    let id = UUID()
    let text = "[Attachment: file.doc](boom-attachment:\(id.uuidString))\n"
      + "[same file](boom-attachment:\(id.uuidString))\n"
      + "[bad](boom-attachment:not-a-uuid)"
    XCTAssertEqual(AttachmentLink.ids(in: text), [id])
    XCTAssertTrue(try ReferenceParser.wiki(text).isEmpty)
  }

  func testMiddleExcerptKeepsBothEndsAndNamesOmission() {
    let source = "ABCDEFGHIJ"
    XCTAssertEqual(ContextExcerpt.middle(source, keeping: 10), source)
    XCTAssertEqual(
      ContextExcerpt.middle(source, keeping: 4),
      "AB\n[6 source characters omitted from the middle]\nIJ")
    XCTAssertEqual(ContextExcerpt.middle("👩🏽‍💻AéZ", keeping: 2).first, "👩🏽‍💻")
  }
  func testFollowedSourceExcerptKeepsEveryIdentityAndBothEnds() throws {
    let a = DocumentSnapshot(title: "A", text: "FIRST" + String(repeating: "a", count: 200) + "LAST")
    let b = DocumentSnapshot(title: "B", text: "START" + String(repeating: "b", count: 200) + "END")
    let root = DocumentSnapshot(title: "Draft", text: "[[A]] [[B]]\nContinue")
    let plan = try ContextGraph.resolve(root: root, all: [root, a, b])
    let excerpt = plan.excerpt(keeping: 32)
    XCTAssertTrue(excerpt.contains("ID \(a.id.uuidString)"))
    XCTAssertTrue(excerpt.contains("ID \(b.id.uuidString)"))
    XCTAssertTrue(excerpt.contains("FIRST"))
    XCTAssertTrue(excerpt.contains("LAST"))
    XCTAssertTrue(excerpt.contains("START"))
    XCTAssertTrue(excerpt.contains("END"))
    XCTAssertTrue(excerpt.contains("source characters omitted from the middle"))
    XCTAssertEqual(plan.excerpt(keeping: Int.max), plan.text)
  }
  func testCompletionChunkPreservesWhitespaceAndGraphemes() {
    let first = CompletionNavigation.nextChunk("  👩🏽‍💻 hello  world")
    XCTAssertEqual(first.accepted, "  👩🏽‍💻 ")
    XCTAssertEqual(first.remaining, "hello  world")
    let second = CompletionNavigation.nextChunk(first.remaining)
    XCTAssertEqual(second.accepted, "hello  ")
    XCTAssertEqual(second.remaining, "world")
    XCTAssertEqual(CompletionNavigation.nextChunk("\n\t").accepted, "\n\t")
  }

}
