import Foundation
import XCTest
@testable import BoomCore

final class ChatConsultationCaptureTests: XCTestCase {
  private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return encoder
  }
  func testLegacyMessageRoundTripKeepsBytesAndDoesNotInventCapture() throws {
    let message = ChatMessage(role: .user, text: "@reader A question.", context: "A public passage.", timestamp: nil)
    let bytes = try encoder().encode(message)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertNil(object["consultationRouting"])
    XCTAssertNil(object["consultationPromptContract"])
    let restored = try JSONDecoder().decode(ChatMessage.self, from: bytes)
    XCTAssertNil(restored.consultationRouting); XCTAssertNil(restored.consultationPromptContract)
    XCTAssertEqual(try encoder().encode(restored), bytes)
    XCTAssertEqual(restored.promptText, "A public passage.\n\nUSER REQUEST\n@reader A question.")
  }
  func testCapturedContextRoutingAndContractSurviveHistoryAndVersionRoundTrip() throws {
    let original = ChatMessage(role: .user, text: "@reader Café?", context: "Cafe\u{301}\nA source.", timestamp: nil,
      consultationRouting: ["reader"], consultationPromptContract: .referenceHistoryV2)
    let edited = ChatMessage(role: .user, text: "@other A revised question.", context: original.context,
      authoredByUser: true, editedFrom: original.id, timestamp: nil)
    var chat = ChatRecord(messages: [edited]); chat.messageVersions = [original]
    let bytes = try encoder().encode(chat)
    let restored = try JSONDecoder().decode(ChatRecord.self, from: bytes)
    XCTAssertEqual(try encoder().encode(restored), bytes)
    let captured = try XCTUnwrap(restored.messageVersions?.first)
    XCTAssertEqual(Data(captured.context.utf8), Data(original.context.utf8))
    XCTAssertEqual(captured.consultationRouting, ["reader"])
    XCTAssertEqual(captured.consultationPromptContract, .referenceHistoryV2)
    XCTAssertNil(restored.messages[0].consultationRouting)
    XCTAssertNil(restored.messages[0].consultationPromptContract)
    XCTAssertEqual(restored.messages[0].editedFrom, original.id)
  }
  func testUnknownCapturedContractIsRejectedRatherThanTreatedAsLegacy() throws {
    let message = ChatMessage(role: .user, text: "Question", timestamp: nil,
      consultationRouting: [], consultationPromptContract: .referenceHistoryV2)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder().encode(message)) as? [String: Any])
    object["consultationPromptContract"] = "unknown_future_contract"
    XCTAssertThrowsError(try JSONDecoder().decode(ChatMessage.self,
      from: JSONSerialization.data(withJSONObject: object)))
  }
  func testV3CaptureRetainsOpaqueContextAndItsVersionWithoutRewritingV2() throws {
    let context = "DOCUMENT 1\n1:Cafe\u{301}.\n\n\nSOURCE BINDINGS\nCURRENT TARGET\nA captured public binding."
    let v3 = ChatMessage(role: .user, text: "@reader Question?", context: context, timestamp: nil,
      consultationRouting: ["reader"], consultationPromptContract: .referenceBindingsV3)
    let v2 = ChatMessage(role: .user, text: "@other Earlier?", context: "An earlier public source.", timestamp: nil,
      consultationRouting: ["other"], consultationPromptContract: .referenceHistoryV2)
    let oldBytes = try encoder().encode(v2)
    let bytes = try encoder().encode(ChatRecord(messages: [v2, v3]))
    let restored = try JSONDecoder().decode(ChatRecord.self, from: bytes)
    XCTAssertEqual(try encoder().encode(restored), bytes)
    XCTAssertEqual(try encoder().encode(restored.messages[0]), oldBytes)
    XCTAssertEqual(restored.messages[1].consultationPromptContract, .referenceBindingsV3)
    XCTAssertEqual(restored.messages[1].consultationRouting, ["reader"])
    XCTAssertEqual(Data(restored.messages[1].context.utf8), Data(context.utf8))
  }
}
