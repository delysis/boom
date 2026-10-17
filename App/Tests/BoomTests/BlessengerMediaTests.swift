import BoomCore
import Foundation
import XCTest
@testable import Boom

extension BlessengerTests {
  func testActualMediaExpansionUsesRealTokensAndChronologicalOccurrences() throws {
    let a = UUID(), b = UUID()
    func payload(_ id: UUID) -> WritingMediaData {
      WritingMediaData(reference: WritingMediaReference(id: id, name: "Caller.wav",
        rootDigest: String(repeating: "a", count: 64), kind: "audio", sourceDigest: String(repeating: "b", count: 64)), bytes: Data(), samples: [0])
    }
    let plan = ConsultationPlan(messages: [
      .init(role: "system", content: "Keep exact instructions.", media: []),
      .init(role: "user", content: "Old🪶 question", media: [.init(id: a, end: "Old🪶".utf8.count)]),
      .init(role: "assistant", content: "Old reply.", media: []),
      .init(role: "user", content: "New", media: [.init(id: b, end: 3), .init(id: a, end: 3)])
    ], rawPrompt: "captured by the core")
    let expanded = try RawWritingInput.expandChatMedia(plan, media: [payload(a), payload(b)])
    XCTAssertEqual(expanded.media.map { $0.reference.id }, [a, b, a])
    XCTAssertEqual(expanded.media.map { $0.reference.sourceDigest }, Array(repeating: String(repeating: "b", count: 64), count: 3))
    XCTAssertEqual(expanded.messages.map(\.role), ["system", "user", "assistant", "user"])
    XCTAssertEqual(expanded.messages[0].content, "Keep exact instructions.")
    XCTAssertEqual(expanded.messages[1].content, "Old🪶\n<|audio|>\n question")
    XCTAssertEqual(expanded.messages[2].content, "Old reply.")
    XCTAssertEqual(expanded.messages[3].content, "New\n<|audio|>\n\n<|audio|>\n")
    XCTAssertFalse(expanded.messages.contains { $0.content.contains("\\(placement") || $0.content.contains("\\n") })
  }

  func testMediaExpansionRejectsMissingAmbiguousForeignAndSplitSourceOccurrences() throws {
    let id = UUID()
    let audio = WritingMediaData(reference: WritingMediaReference(id: id, name: "Caller.wav",
      rootDigest: String(repeating: "a", count: 64), kind: "audio"), bytes: Data(), samples: [0])
    func plan(role: String = "user", end: Int = 4) -> ConsultationPlan {
      ConsultationPlan(messages: [.init(role: role, content: "🪶", media: [.init(id: id, end: end)])], rawPrompt: "fixture")
    }
    for role in ["assistant", "system", "tool"] { XCTAssertThrowsError(try RawWritingInput.expandChatMedia(plan(role: role), media: [audio])) }
    for end in [-1, 1, 2, 3, 5, Int.max] { XCTAssertThrowsError(try RawWritingInput.expandChatMedia(plan(end: end), media: [audio])) }
    XCTAssertThrowsError(try RawWritingInput.expandChatMedia(plan(), media: []))
    XCTAssertThrowsError(try RawWritingInput.expandChatMedia(plan(), media: [audio, audio]))
    let mixed = ConsultationPlan(messages: [.init(role: "system", content: "missing contract"), plan().messages[0]], rawPrompt: "fixture")
    XCTAssertThrowsError(try RawWritingInput.expandChatMedia(mixed, media: [audio]))
    XCTAssertEqual(try RawWritingInput.expandChatMedia(plan(), media: [audio]).messages[0].content, "🪶\n<|audio|>\n")
  }
}
