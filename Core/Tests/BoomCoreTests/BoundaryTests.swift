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
  private func be32(_ n: UInt32) -> Data {
    Data([
      UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
      UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n),
    ])
  }
  private func atom(_ type: String, _ payload: Data) -> Data {
    be32(UInt32(payload.count + 8)) + Data(type.utf8) + payload
  }
  private func reference(_ flags: UInt32 = 1, _ type: String = "url ") -> Data {
    atom(type, be32(flags))
  }
  private func movie(_ entry: Data? = nil, count: UInt32 = 1) -> Data {
    let dref = atom("dref", be32(0) + be32(count) + (entry ?? reference()))
    return atom("ftyp", Data("isom".utf8))
      + atom("moov", atom("trak", atom("mdia", atom("minf", atom("dinf", dref)))))
  }
  func testSelfContainedMP4ReferenceAllowed() throws {
    XCTAssertTrue(try MediaContainerPolicy.selfContainedMP4(movie()))
  }
  func testExternalMP4ReferenceRejected() {
    XCTAssertThrowsError(try MediaContainerPolicy.selfContainedMP4(movie(reference(0))))
  }
  func testMP4URNReferenceRejected() {
    XCTAssertThrowsError(try MediaContainerPolicy.selfContainedMP4(movie(reference(1, "urn "))))
  }
  func testMP4ReferenceCountMismatchRejected() {
    XCTAssertThrowsError(try MediaContainerPolicy.selfContainedMP4(movie(count: 2)))
  }
  func testMP4ReferenceTrailingPayloadRejected() {
    XCTAssertThrowsError(try MediaContainerPolicy.selfContainedMP4(movie(reference() + Data([0]))))
  }
  func testMP4WithoutDataReferencesNotAdmitted() throws {
    XCTAssertFalse(try MediaContainerPolicy.selfContainedMP4(atom("ftyp", Data("isom".utf8))))
  }
  func testExtendedMP4SizeCannotOverflow() {
    let malformed =
      atom("ftyp", Data("isom".utf8)) + be32(1) + Data("moov".utf8) + Data(repeating: 255, count: 8)
    XCTAssertThrowsError(try MediaContainerPolicy.selfContainedMP4(malformed))
  }
  func testMP4NestedAtomBudget() {
    var child = atom("dref", be32(0) + be32(1) + reference())
    for _ in 0..<15 { child = atom("moov", child) }
    XCTAssertThrowsError(
      try MediaContainerPolicy.selfContainedMP4(atom("ftyp", Data("isom".utf8)) + child))
  }
  func testDataSliceOffsetsAreNormalized() throws {
    let bytes = Data([255]) + movie()
    XCTAssertTrue(try MediaContainerPolicy.selfContainedMP4(bytes.dropFirst()))
  }
  func testPlaylistsAndReferenceMoviesAreNotMP4() throws {
    for s in ["#EXTM3U\nhttps://example.com/a.m3u8", "https://example.com/video.mp4", ""] {
      XCTAssertFalse(try MediaContainerPolicy.selfContainedMP4(Data(s.utf8)))
    }
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
