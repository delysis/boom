import XCTest

@testable import BoomCore

final class BoundaryTests: XCTestCase {
  func testMarkdownAndHTMLRemainExact() {
    let text = "<div class=\"note\">A & B</div>\n3 < 5 > 2; <https://example.org>"
    XCTAssertEqual(GemmaPrompt.safe(text), text)
  }
  func testAllProtocolSpellingsEscapedAndIdempotent() {
    for token in [
      "<bos>", "<eos>", "<|turn>", "<turn|>", "<|image|>", "<|audio>", "<audio|>", "<|think|>",
      "<|channel>", "<channel|>", "<|tool_call>", "<tool_call|>", "<|\"|>",
    ] {
      let safe = GemmaPrompt.safe(token)
      XCTAssertFalse(safe.contains(token))
      XCTAssertEqual(safe, GemmaPrompt.safe(safe))
    }
  }
  func testGemmaConversationHasNoHiddenSystemTurn() {
    let prompt = GemmaPrompt.conversation(history: [], request: "Hello")
    XCTAssertTrue(prompt.hasPrefix("<bos><|turn>user\nHello<turn|>"))
    XCTAssertFalse(prompt.contains("<|turn>system"))
    XCTAssertEqual(prompt.components(separatedBy: "<|turn>user").count, 2)
    XCTAssertTrue(prompt.hasSuffix("<|turn>model\n"))
    XCTAssertFalse(prompt.contains("<|think|>"))
  }
  func testConsecutiveAssistantTurnsAreMerged() {
    let history = [
      ChatMessage(role: .user, text: "A"), ChatMessage(role: .assistant, text: "B"),
      ChatMessage(role: .assistant, text: "C"),
    ]
    let prompt = GemmaPrompt.conversation(history: history, request: "D")
    XCTAssertTrue(prompt.contains("model\nB\n\nC<turn|>"))
  }
  func testConsecutiveUserTurnsAreMerged() {
    let prompt = GemmaPrompt.conversation(
      history: [ChatMessage(role: .user, text: "First")], request: "Second")
    XCTAssertTrue(prompt.contains("user\nFirst\n\nSecond<turn|>"))
  }
  func testPersonaNeedsACompleteExchangeBeforeNativePrefill() {
    XCTAssertThrowsError(try GemmaPrompt.prefix([]))
    XCTAssertThrowsError(try GemmaPrompt.prefix([ChatMessage(role: .user, text: "Unanswered")]))
    XCTAssertThrowsError(try GemmaPrompt.prefix([ChatMessage(role: .assistant, text: "No user")]))
  }
  func testMultilineInlineCodeCannotImportReferences() throws {
    XCTAssertEqual(
      try ReferenceParser.wiki("`code\n[[Hidden]]\n` [[Visible]]").map(\.title), ["Visible"])
    XCTAssertTrue(try ReferenceParser.personas("`code\n@hidden\n`").isEmpty)
  }
  func testBackslashInInlineCodeDoesNotHideTheClosingDelimiter() throws {
    XCTAssertEqual(try ReferenceParser.wiki("`code\\` [[Visible]]").map(\.title), ["Visible"])
  }
  func testFollowPrefixExcludesCurrentDraftAndIsActualPromptPrefix() throws {
    let reference = DocumentSnapshot(title: "Style", text: "Use short sentences.")
    let a = DocumentSnapshot(title: "Draft", text: "[[Style]] A")
    let b = DocumentSnapshot(id: a.id, title: a.title, text: "[[Style]] B")
    let ga = try ContextGraph.resolve(root: a, all: [a, reference])
    let gb = try ContextGraph.resolve(root: b, all: [b, reference])
    XCTAssertEqual(GemmaPrompt.followedPrefix(ga), GemmaPrompt.followedPrefix(gb))
    let prefix = try XCTUnwrap(GemmaPrompt.followedPrefix(ga))
    XCTAssertTrue(prefix.hasPrefix("<bos>"))
    XCTAssertFalse(prefix.contains("<|turn>"))
    XCTAssertTrue(
      try GemmaPrompt.completion(document: a, caretUTF16: a.text.utf16.count, context: ga)
        .hasPrefix(prefix))
    XCTAssertFalse(prefix.contains("[[Style]] A"))
  }
  func testNoFollowCacheForAnUnlinkedDocument() throws {
    let d = DocumentSnapshot(title: "Draft", text: "Hello")
    XCTAssertNil(GemmaPrompt.followedPrefix(try ContextGraph.resolve(root: d, all: [d])))
  }
  func testFollowPrefixChangesOnSourceRenameEvenWhenBytesDoNot() throws {
    let r = DocumentSnapshot(title: "Before", text: "Context")
    let d = DocumentSnapshot(title: "Draft", text: "[[Stable|\(r.id)]]")
    let renamed = DocumentSnapshot(id: r.id, title: "After", text: r.text)
    let a = try ContextGraph.resolve(root: d, all: [d, r])
    let b = try ContextGraph.resolve(root: d, all: [d, renamed])
    XCTAssertNotEqual(GemmaPrompt.followedPrefix(a), GemmaPrompt.followedPrefix(b))
  }
  func testCacheRuntimeRevisionAndContextArePartOfIdentity() throws {
    let original = ModelIdentity(manifestDigest: "m", runtimeRevision: "r1", contextLength: 2048)
    let data = Data([1])
    let cache = CacheDescriptor(
      model: original, prefixDigest: Digest.sha256("p"), payload: data, tokenCount: 1)
    for changed in [
      ModelIdentity(manifestDigest: "m", runtimeRevision: "r2", contextLength: 2048),
      ModelIdentity(manifestDigest: "m", runtimeRevision: "r1", contextLength: 4096),
    ] {
      XCTAssertThrowsError(try cache.validate(model: changed, prefix: "p", payload: data))
    }
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
  func testMalformedEditNeverPartiallyApplies() {
    let original = DocumentSnapshot(title: "Text", text: "alpha beta")
    let patch = DocumentPatch(
      documentID: original.id, revision: original.revision,
      replacements: [Replacement(old: "alpha", new: "A"), Replacement(old: "missing", new: "B")])
    XCTAssertThrowsError(
      try DocumentTools.apply(
        patch, grant: DocumentGrant(mode: .edit, snapshot: original), current: original))
    XCTAssertEqual(original.text, "alpha beta")
  }
  func testLiteralHTMLCanBeAnExactEditAnchor() throws {
    let original = DocumentSnapshot(title: "Text", text: "<aside>Old</aside>")
    let patch = DocumentPatch(
      documentID: original.id, revision: original.revision,
      replacements: [Replacement(old: "<aside>Old</aside>", new: "<aside>New</aside>")])
    XCTAssertEqual(
      try DocumentTools.apply(
        patch, grant: DocumentGrant(mode: .edit, snapshot: original), current: original
      ).text, "<aside>New</aside>")
  }
  func testCaretWindowKeepsGraphemeBoundaries() throws {
    let prefix = "Outside 🧑🏽‍💻e\u{301}"
    let suffix = "👨‍👩‍👧‍👦tail"
    let d = DocumentSnapshot(title: "Unicode", text: prefix + suffix)
    let w = try CompletionWindow(
      document: d, caretUTF16: prefix.utf16.count, prefixCharacters: 2, suffixCharacters: 1)
    XCTAssertEqual(w.before, "🧑🏽‍💻e\u{301}")
    XCTAssertEqual(w.after, "👨‍👩‍👧‍👦")
    XCTAssertTrue(w.isExcerpt)
    XCTAssertTrue(w.scopeDescription.contains("not supplied"))
    XCTAssertEqual(w.startUTF16 + w.before.utf16.count, prefix.utf16.count)
  }
  func testCaretWindowAdmitsEntireShortDocument() throws {
    let d = DocumentSnapshot(title: "Text", text: "abcdef")
    let w = try CompletionWindow(document: d, caretUTF16: 3)
    XCTAssertEqual(w.before, "abc")
    XCTAssertEqual(w.after, "def")
    XCTAssertFalse(w.isExcerpt)
    XCTAssertEqual(w.scopeDescription, "entire document")
  }
  func testCaretWindowRejectsInvalidBoundaryAndNegativeBudget() {
    let d = DocumentSnapshot(title: "Unicode", text: "😀")
    XCTAssertThrowsError(try CompletionWindow(document: d, caretUTF16: 1))
    XCTAssertThrowsError(try CompletionWindow(document: d, caretUTF16: 0, prefixCharacters: -1))
    XCTAssertThrowsError(try CompletionWindow(document: d, caretUTF16: 3))
  }
  func testEmptyCaretWindowDoesNotClaimFullSourceCoverage() throws {
    let d = DocumentSnapshot(title: "Text", text: "before after")
    let w = try CompletionWindow(
      document: d, caretUTF16: 7, prefixCharacters: 0, suffixCharacters: 0)
    XCTAssertTrue(w.before.isEmpty)
    XCTAssertTrue(w.after.isEmpty)
    XCTAssertTrue(w.isExcerpt)
    XCTAssertEqual(w.startUTF16, w.endUTF16)
  }
  func testCompletionPromptUsesOnlyBoundedAuthorText() throws {
    let d = DocumentSnapshot(title: "Long", text: String(repeating: "x", count: 10_000))
    let g = try ContextGraph.resolve(root: d, all: [d])
    let p = try GemmaPrompt.completion(
      document: d, caretUTF16: 9000, context: g, prefixCharacters: 16, suffixCharacters: 8)
    XCTAssertTrue(p.contains(String(repeating: "x", count: 16)))
    XCTAssertFalse(p.contains(String(repeating: "x", count: 25)))
    XCTAssertFalse(p.contains("Continue the Markdown"))
    XCTAssertFalse(p.contains("<|turn>"))
  }
  func testDocumentCompletionIsRawContinuation() throws {
    let document = DocumentSnapshot(title: "Draft", text: "If I start")
    let context = try ContextGraph.resolve(root: document, all: [document])
    XCTAssertEqual(
      try GemmaPrompt.completion(document: document, caretUTF16: document.text.utf16.count,
        context: context), "<bos>If I start")
    XCTAssertThrowsError(
      try GemmaPrompt.completion(document: document, caretUTF16: 0, context: context))
  }
  func testCompletionStopsBeforeSecondParagraph() {
    XCTAssertEqual(
      GemmaPrompt.visibleCompletion("100 feet tall.\n\n[[Voice]]"), "100 feet tall.")
    XCTAssertNil(GemmaPrompt.visibleCompletion("<|turn>model"))
  }
  func testDocumentAttachmentLinksAreStableAndDeduplicated() throws {
    let id = UUID()
    let text = "[Attachment: file.doc](boom-attachment:\(id.uuidString))\n"
      + "[same file](boom-attachment:\(id.uuidString))\n"
      + "[bad](boom-attachment:not-a-uuid)"
    XCTAssertEqual(AttachmentLink.ids(in: text), [id])
    XCTAssertTrue(try ReferenceParser.wiki(text).isEmpty)
  }

  func testAutomaticGemmaSizeUsesPhysicalMemoryAndMobileFootprints() {
    func recommendation(_ gb: UInt64) -> GemmaSize? {
      ModelMemoryPolicy.recommendedSize(physicalBytes: gb * 1_000_000_000)
    }
    XCTAssertEqual(recommendation(32), .b31)
    XCTAssertEqual(recommendation(16), .b12)
    XCTAssertEqual(recommendation(8), .e4b)
    XCTAssertEqual(recommendation(4), .e2b)
    XCTAssertNil(recommendation(2))
    XCTAssertEqual(recommendation(128), .b31)
    XCTAssertEqual(GemmaSize.b31.qatRepository, "google/gemma-4-31B-it-qat-q4_0-gguf")
    XCTAssertEqual(
      GemmaSize.b31.qatAssistantRepository,
      "google/gemma-4-31B-it-qat-q4_0-unquantized-assistant")
    XCTAssertEqual(
      GemmaSize.e2b.mobileRepository,
      "google/gemma-4-E2B-it-qat-mobile-transformers")
  }
  func testContextBudgetReservesWorkingMemoryAndHonorsModelLimit() {
    XCTAssertEqual(
      ModelMemoryPolicy.maximumContext(
        architectureLimit: 262_144, workingSetBytes: 32_000_000_000,
        residentBytes: 20_000_000_000, kvBytesPerToken: 1_000_000), 8_800)
    XCTAssertEqual(
      ModelMemoryPolicy.maximumContext(
        architectureLimit: 2048, workingSetBytes: 32_000_000_000,
        residentBytes: 20_000_000_000, kvBytesPerToken: 1_000_000), 2048)
    XCTAssertEqual(
      ModelMemoryPolicy.maximumContext(
        architectureLimit: 262_144, workingSetBytes: 16_000_000_000,
        residentBytes: 15_000_000_000, kvBytesPerToken: 1_000_000), 0)
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
