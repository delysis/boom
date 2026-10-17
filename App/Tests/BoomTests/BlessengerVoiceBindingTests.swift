import BoomCore
import Foundation
import XCTest
@testable import Boom

final class BlessengerVoiceBindingTests: XCTestCase {
  private func fixture() async throws -> (WorkspaceStore, WorkspaceState, [Voice]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Blessenger-voices-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(rootOverride: root,
      privateSession: BlessengerKeySession { _ in Data(repeating: 0x42, count: 32) })
    _ = try await store.openBlessenger(catalog: BlessengerCatalog(sourceRevision: "fixture", sourceSHA256: "fixture", entries: []))
    let voices = try (1...2).map { n in
      try ProductCore.voice(VoiceDraft(id: UUID(), slug: "fixture-\(n)", name: "Consultant \(n)", instructions: "Unchanged source prompt."))
    }
    let state = try await store.blessengerTransaction { state, _ in
      for voice in voices {
        state.chats.append(ChatRecord(id: voice.id, title: voice.name, instructions: voice.instructions))
        state.voices.append(voice)
      }
    }.0
    return (store, state, voices)
  }
  func testVoiceSaveTargetsCapturedContactAndLeavesPromptsAndOtherBindingsIntact() async throws {
    let (store, before, contacts) = try await fixture()
    var designed = before.blessenger!.defaultSpeech
    designed.description = "  A measured English baritone.\nGentle delivery. 🪷  "
    let captured = BlessengerVoiceEdit(contact: contacts[0], product: before.blessenger!)
    XCTAssertNil(captured.expected, "An inherited default is not an existing override.")
    _ = try await store.blessengerSelect(contacts[1].id, template: true)
    let next = try await store.blessengerSetSpeechVoice(contactID: contacts[0].id, expected: captured.expected, replacement: designed)
    XCTAssertEqual(next.blessenger!.speechVoices[contacts[0].id], designed)
    XCTAssertNil(next.blessenger!.speechVoices[contacts[1].id])
    XCTAssertEqual(next.blessenger!.defaultSpeech, before.blessenger!.defaultSpeech)
    XCTAssertEqual(next.voices, before.voices)
    XCTAssertEqual(next.chats, before.chats)
    XCTAssertEqual(next.selectedChat, contacts[1].id)
    try await store.releaseExclusiveWorkspace()
  }
  func testStaleSpeechSaveCannotOverwriteNewerChoiceAndDefaultResetIsExplicit() async throws {
    let (store, before, contacts) = try await fixture()
    let original = before.blessenger!.defaultSpeech
    var first = original; first.description = "A calm alto."
    _ = try await store.blessengerSetSpeechVoice(contactID: contacts[0].id, expected: nil, replacement: first)
    var stale = original; stale.description = "A stale edit."
    do {
      _ = try await store.blessengerSetSpeechVoice(contactID: contacts[0].id, expected: nil, replacement: stale)
      XCTFail("The stale voice editor overwrote a newer binding")
    } catch {}
    let retained = try await store.blessengerSnapshot()
    XCTAssertEqual(retained.blessenger!.speechVoices[contacts[0].id], first)
    let reset = try await store.blessengerSetSpeechVoice(contactID: contacts[0].id, expected: first, replacement: nil)
    XCTAssertNil(reset.blessenger!.speechVoices[contacts[0].id])
    XCTAssertEqual(reset.blessenger!.defaultSpeech, original)
    do {
      _ = try await store.blessengerSetSpeechVoice(contactID: nil, expected: original, replacement: nil)
      XCTFail("The default voice cannot be removed")
    } catch {}
    try await store.releaseExclusiveWorkspace()
  }
  func testVoiceCompareAndReplaceDistinguishesUnicodeByteIdentities() async throws {
    let (store, before, contacts) = try await fixture()
    var original = before.blessenger!.defaultSpeech; original.description = "A measured café voice."
    _ = try await store.blessengerSetSpeechVoice(contactID: contacts[0].id, expected: nil, replacement: original)
    var differentBytes = original; differentBytes.description = "A measured cafe\u{301} voice."
    XCTAssertEqual(original.description, differentBytes.description, "Swift String equality normalizes Unicode.")
    XCTAssertNotEqual(Array(original.description.utf8), Array(differentBytes.description.utf8))
    do {
      _ = try await store.blessengerSetSpeechVoice(contactID: contacts[0].id, expected: differentBytes, replacement: nil)
      XCTFail("Canonical String equality bypassed the exact captured edit witness")
    } catch {}
    let after = try await store.blessengerSnapshot()
    XCTAssertEqual(Array(after.blessenger!.speechVoices[contacts[0].id]!.description.utf8), Array(original.description.utf8))
    try await store.releaseExclusiveWorkspace()
  }
  func testRemovedContactAndInvalidVoiceCannotBecomeNewBindingOwners() async throws {
    let (store, before, contacts) = try await fixture()
    let original = before.blessenger!.defaultSpeech
    var bad = original; bad.locale = "unimplemented-language"
    do {
      _ = try await store.blessengerSetSpeechVoice(contactID: contacts[0].id, expected: nil, replacement: bad)
      XCTFail("An unsupported language was accepted and ignored")
    } catch {}
    var state = try await store.blessengerSnapshot()
    XCTAssertEqual(state.blessenger!.generation, before.blessenger!.generation)
    state = try await store.blessengerTransaction { state, _ in
      state.voices.removeAll { $0.id == contacts[0].id }
    }.0
    do {
      _ = try await store.blessengerSetSpeechVoice(contactID: contacts[0].id, expected: nil, replacement: original)
      XCTFail("A removed Contact accepted a late voice save")
    } catch {}
    let after = try await store.blessengerSnapshot()
    XCTAssertEqual(after.blessenger!.generation, state.blessenger!.generation)
    try await store.releaseExclusiveWorkspace()
  }
}
