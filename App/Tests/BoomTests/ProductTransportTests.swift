import BoomCore
import XCTest
@testable import Boom

final class ProductTransportTests: XCTestCase {
  func testExactEightMiBImportSurvivesWorstCaseJSONEscaping() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-transport-import-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let bytes = Data(repeating: 1, count: 2_097_152)
    let urls = try (0..<4).map { index in
      let url = root.appendingPathComponent("part-\(index).txt")
      try bytes.write(to: url)
      return url
    }
    let files = try urls.map { url -> ImportedText in
      let original = try AttachmentProcessor.readGranted(url, limit: 2_097_152, allowEmpty: true)
      XCTAssertEqual(original, bytes)
      let text = try XCTUnwrap(String(data: original, encoding: .utf8))
      XCTAssertEqual(Data(text.utf8), bytes)
      return ImportedText(path: url.lastPathComponent, text: text)
    }
    try ProductCore.admitImportedTexts(files, documents: true)
    let chosen = try FolderImport.chosenFiles(root, flag: CancellationFlag())
    XCTAssertEqual(chosen.map(\.path), urls.map(\.lastPathComponent))
    for file in chosen { XCTAssertEqual(try Data(contentsOf: file.url), bytes) }
    try ProductCore.admitImportedTexts(files)
    XCTAssertThrowsError(try ProductCore.importedDocuments(files)) { error in
      guard case BoomError.budget = error else { return XCTFail("Capacity lost its type: \(error)") }
    }
  }

  func testSharedNineTurnHistoryFitsThreeVoicesWithoutLosingPromptBytes() throws {
    let voices = try ["one", "two", "three"].map {
      try ProductCore.voice(VoiceDraft(slug: $0, name: $0, instructions: "Read the captured exchange."))
    }
    let history = (0..<9).map { index in
      ChatMessage(role: index % 2 == 0 ? .user : .assistant,
        text: "\(index)" + String(repeating: "x", count: 499_999),
        speaker: index % 2 == 0 ? Speaker(name: "Human") : voices[0].speaker)
    }
    let plans = try ProductCore.consultationRound(voices: voices, history: history,
      instructions: "", context: "", request: "@one @two @three Continue.", routing: ["one", "two", "three"])
    XCTAssertEqual(plans.count, 3)
    for plan in plans {
      for turn in history {
        XCTAssertTrue(plan.rawPrompt.contains(turn.text))
        XCTAssertTrue(plan.messages.contains { $0.content.contains(turn.text) })
      }
      XCTAssertTrue(plan.rawPrompt.hasSuffix("<|turn>model\n<|channel>thought\n<channel|>"))
    }
    XCTAssertNotEqual(plans[0].rawPrompt, plans[1].rawPrompt,
      "Captured speaker authority must remain specific to each participant.")
  }

  func testCapacityFailuresStayDistinctFromInvalidInput() throws {
    XCTAssertThrowsError(try ProductCore.call(["op": "layout", "excess": String(repeating: "x", count: 16_777_216)], as: ProductLayout.self)) { error in
      guard case BoomError.budget = error else { return XCTFail("Oversized request was not typed capacity") }
    }
    XCTAssertThrowsError(try ProductCore.admitImportedTexts([
      ImportedText(path: "good.txt", text: "Captured good text."),
      ImportedText(path: "bad.txt", text: "Invalid\0text.")])) { error in
      guard case BoomError.invalid = error else { return XCTFail("Invalid text was classified as trimmable capacity") }
    }
    XCTAssertThrowsError(try ProductCore.admitImportedTexts([
      ImportedText(path: "same.txt", text: "a"), ImportedText(path: "same.txt", text: "b")])) { error in
      guard case BoomError.invalid = error else { return XCTFail("Duplicate paths were classified as capacity") }
    }
    XCTAssertNoThrow(try ProductCore.admitImportedTexts([
      ImportedText(path: "same.txt", text: "a"), ImportedText(path: "same.txt", text: "b")], documents: true))
  }
}
