import BoomCore
import XCTest
@testable import Boom

final class GeneratedTextTests: XCTestCase {
  func testAuthoredPrefixUsesUnicodeCaretAndOmitsFollowingText() throws {
    let doc = DocumentSnapshot(title: "Draft", text: "é🦋 before|after")
    XCTAssertEqual(try ProductCore.authoredPrefix(doc, caret: 10), "é🦋 before")
    XCTAssertThrowsError(try ProductCore.authoredPrefix(doc, caret: 2))
  }
  func testCapturedVoiceRevisionAndSpeakerAttribution() throws {
    let first = try ProductCore.voice(VoiceDraft(slug: "sage", name: "Sage", instructions: "First approach"))
    var edited = first.draft; edited.instructions = "A new approach"; edited.name = "Renamed"
    let second = try ProductCore.voice(edited)
    XCTAssertNotEqual(first.revision, second.revision)
    let message = ChatMessage(role: .assistant, text: "Original answer", speaker: first.speaker)
    let plan = try ProductCore.prompt(voice: second, history: [message], instructions: "", context: "", request: "Another question", routing: [])
    XCTAssertTrue(plan.rawPrompt.contains("Sage")); XCTAssertTrue(plan.rawPrompt.contains("Original answer"))
    XCTAssertFalse(plan.messages.filter { $0.role == "assistant" }.contains { $0.content == "Original answer" })
    XCTAssertEqual(message.speaker?.voiceRevision, first.revision)
  }
  func testLexicalOpeningsRemainAvailable() {
    XCTAssertTrue(GemmaPrompt.admissibleCompletion("Here is the continuation:"))
    XCTAssertTrue(GemmaPrompt.admissibleCompletion("<3 forever"))
  }
}
