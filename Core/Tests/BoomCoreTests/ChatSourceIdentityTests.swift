import Foundation
import XCTest
@testable import BoomCore

final class ChatSourceIdentityTests: XCTestCase {
  func testContextIdentityIsLocalAndPreservesEncodedFieldsAfterDecode() throws {
    var chat = ChatRecord(title: "Public chat", messages: [ChatMessage(role: .user, text: "Cafe\u{301}")],
      attachedDocumentID: UUID(), instructions: "Answer briefly.")
    chat.messageVersions = [ChatMessage(role: .assistant, text: "A retained answer.")]
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let bytes = try encoder.encode(chat)
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(Set(fields.keys), Set(["id", "title", "messages", "attachedDocumentID", "instructions", "messageVersions"]))
    let restored = try JSONDecoder().decode(ChatRecord.self, from: bytes)
    XCTAssertEqual(restored, chat)
    XCTAssertNotEqual(restored.contentVersion, chat.contentVersion)
    XCTAssertEqual(try encoder.encode(restored), bytes)
    XCTAssertEqual(Digest.sha256(try encoder.encode(restored)), Digest.sha256(bytes))
  }

  func testNestedEncodedMutationsInvalidateCopiesWithoutChangingValueEquality() throws {
    let original = ChatRecord(title: "Public chat", messages: [ChatMessage(role: .user, text: "Café")],
      instructions: "Café")
    let mutations: [(inout ChatRecord) -> Void] = [
      { $0.title.append(" renamed") },
      { $0.messages.append(ChatMessage(role: .assistant, text: "A reply.")) },
      { $0.messages[0].text = "Cafe\u{301}" },
      { $0.messages[0].state = .cancelled },
      { $0.attachedDocumentID = UUID() },
      { $0.instructions = "Cafe\u{301}" },
      { $0.messageVersions = [ChatMessage(role: .user, text: "A retained question.")] },
    ]
    for mutate in mutations {
      var first = original, second = original
      XCTAssertEqual(first.contentVersion, original.contentVersion)
      mutate(&first); mutate(&second)
      XCTAssertNotEqual(first.contentVersion, original.contentVersion)
      XCTAssertNotEqual(first.contentVersion, second.contentVersion)
      XCTAssertEqual(original.messages[0].text, "Café")
    }
    var canonical = original; canonical.instructions = "Cafe\u{301}"
    XCTAssertEqual(canonical, original, "Value equality remains canonical; it is not context ownership.")
    XCTAssertNotEqual(canonical.contentVersion, original.contentVersion)
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    XCTAssertNotEqual(Digest.sha256(try encoder.encode(canonical)), Digest.sha256(try encoder.encode(original)))
  }
}
