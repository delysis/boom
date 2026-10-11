import Foundation
import XCTest
@testable import BoomCore

final class ChatReadingIdentityTests: XCTestCase {
  private func message() -> ChatMessage {
    ChatMessage(role: .assistant, text: "Café 👩🏽‍💻.", context: "Café context.",
      sources: [SourceReference(id: UUID(), title: "Public source", digest: "public", kind: "document")],
      state: .pending, provider: "unit-fixture", feedback: .helpful,
      speaker: Speaker(name: "Reader", voiceID: UUID(), voiceRevision: "public"),
      failure: "A retained failure.", authoredByUser: true, editedFrom: UUID(),
      timestamp: Date(timeIntervalSince1970: 1_700_000_000), directAttachments: [UUID()],
      consultationRouting: ["reader"], consultationPromptContract: .referenceHistoryV2)
  }
  private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return encoder
  }

  func testCopiesAndNestedCharacterMutationsOwnNewReadingIdentities() {
    let original = message(), originalVersion = original.readingVersion
    let mutations: [(inout ChatMessage) -> Void] = [
      { $0.text = "Cafe\u{301} 👩🏽‍💻." },
      { $0.text.append(" A lantern.") },
      { $0.text.replaceSubrange($0.text.startIndex..<$0.text.index(after: $0.text.startIndex), with: "A") },
      { $0.state = .complete },
      { $0.failure = "A different retained failure." },
    ]
    for mutate in mutations {
      var first = original, second = original
      XCTAssertEqual(first.readingVersion, originalVersion)
      mutate(&first); mutate(&second)
      XCTAssertNotEqual(first.readingVersion, originalVersion)
      XCTAssertNotEqual(second.readingVersion, originalVersion)
      XCTAssertNotEqual(first.readingVersion, second.readingVersion)
      XCTAssertEqual(original.readingVersion, originalVersion)
      XCTAssertEqual(Data(original.text.utf8), Data("Café 👩🏽‍💻.".utf8))
    }
    var chat = ChatRecord(messages: [original])
    let contextVersion = chat.contentVersion
    chat.messages[0].text.append(" Streaming prose.")
    XCTAssertNotEqual(chat.messages[0].readingVersion, originalVersion)
    XCTAssertNotEqual(chat.contentVersion, contextVersion, "Existing context ownership must still observe nested changes.")
    var metadata = original
    metadata.context += " More context."; metadata.sources = []; metadata.provider = "other"
    metadata.feedback = .unhelpful; metadata.speaker = Speaker(name: "Other")
    metadata.authoredByUser = false; metadata.editedFrom = UUID()
    XCTAssertEqual(metadata.readingVersion, originalVersion, "Unrelated metadata does not alter the derived reading text.")
  }

  func testRuntimeIdentityIsUnencodedAndCannotBeSuppliedByDecodedRecords() throws {
    let original = message(), bytes = try encoder().encode(original)
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(Set(fields.keys), Set([
      "id", "role", "timestamp", "text", "context", "sources", "directAttachments", "state",
      "provider", "feedback", "speaker", "failure", "authoredByUser", "editedFrom",
      "consultationRouting", "consultationPromptContract"
    ]))
    var hostile = fields
    hostile["readingVersion"] = original.readingVersion.uuidString
    let restored = try JSONDecoder().decode(ChatMessage.self,
      from: JSONSerialization.data(withJSONObject: hostile))
    XCTAssertNotEqual(restored.readingVersion, original.readingVersion)
    XCTAssertEqual(restored, original)
    XCTAssertEqual(try encoder().encode(restored), bytes)
    var canonical = original
    canonical.text = "Cafe\u{301} 👩🏽‍💻."
    XCTAssertEqual(canonical, original, "Ordinary equality retains canonical String semantics.")
    XCTAssertNotEqual(canonical.readingVersion, original.readingVersion)
    XCTAssertNotEqual(Data(canonical.text.utf8), Data(original.text.utf8))

    let legacy = """
      {"id":"00000000-0000-0000-0000-000000000001","role":"assistant",
       "text":"Retained answer.","context":"","sources":[],"state":"complete"}
      """
    let old = try JSONDecoder().decode(ChatMessage.self, from: Data(legacy.utf8))
    XCTAssertNil(old.timestamp); XCTAssertNil(old.consultationRouting)
    XCTAssertNil(old.consultationPromptContract); XCTAssertNil(old.failure)
    XCTAssertNotEqual(try JSONDecoder().decode(ChatMessage.self, from: Data(legacy.utf8)).readingVersion,
      old.readingVersion)
  }

  func testValueEqualityStillIncludesEveryExistingEncodedField() throws {
    let original = message()
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder().encode(original)) as? [String: Any])
    let alternatives: [(String, Any)] = [
      ("id", UUID().uuidString), ("role", "user"), ("timestamp", 100.0), ("text", "Changed answer."),
      ("context", "Changed context."), ("sources", [[String: Any]]()),
      ("directAttachments", [UUID().uuidString]), ("state", "cancelled"), ("provider", "other"),
      ("feedback", "unhelpful"), ("speaker", ["name": "Other"]), ("failure", "Other failure."),
      ("authoredByUser", false), ("editedFrom", UUID().uuidString),
      ("consultationRouting", ["other"]), ("consultationPromptContract", "reference_bindings_v3"),
    ]
    for (key, value) in alternatives {
      var changed = fields; changed[key] = value
      let decoded = try JSONDecoder().decode(ChatMessage.self,
        from: JSONSerialization.data(withJSONObject: changed))
      XCTAssertNotEqual(decoded, original, "Value equality omitted \(key).")
    }
  }
}
