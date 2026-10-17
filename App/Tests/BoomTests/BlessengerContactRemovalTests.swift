import AppKit
import BoomCore
import Foundation
import XCTest
@testable import Boom

final class BlessengerContactRemovalTests: XCTestCase {
  @MainActor func testLibraryRemovalPreservesUnsentAudienceAndRequiresExplicitReaddressing() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Blessenger-contact-removal-" + UUID().uuidString)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    let catalog = BlessengerCatalog(sourceRevision: "fixture", sourceSHA256: "fixture", entries: [])
    let store = try WorkspaceStore(rootOverride: root,
      privateSession: BlessengerKeySession { _ in Data(repeating: 0x56, count: 32) })
    _ = try await store.openBlessenger(catalog: catalog)
    let first = ChatRecord(title: "First consultant", instructions: "First fixture instructions")
    let second = ChatRecord(title: "Second consultant", instructions: "Second fixture instructions")
    let firstVoice = try ProductCore.pinnedVoice(first, slug: "first", occupied: [])
    let secondVoice = try ProductCore.pinnedVoice(second, slug: "second", occupied: ["first"])
    let contacts = [BlessengerContact(firstVoice), BlessengerContact(secondVoice)]
    let group = BlessengerGroup(id: UUID(), handle: "chosen-pair", name: "Chosen pair", members: contacts)
    let initial = try await store.blessengerTransaction { state, product in
      state.chats = [first, second]; state.voices = [firstVoice, secondVoice]
      product.groups = [group]
      product.drafts[0].text = "  Exact question cafe\u{301} 🪶\r\n"
      product.drafts[0].recipients = contacts; product.drafts[0].groupName = "Chosen pair"
      product.drafts[0].version = UUID()
    }.0
    let before = initial.blessenger!.draft(for: nil)
    let model = BlessengerModel(store: store, catalog: catalog, state: initial, namespace: UUID())
    await model.remove(first.id) // the actual library action, not a test-only mutation
    let removed = try await store.blessengerSnapshot()
    XCTAssertEqual(try BlessengerPolicy.exactDigest(model.draft), try BlessengerPolicy.exactDigest(before))
    XCTAssertEqual(try BlessengerPolicy.exactDigest(removed.blessenger!.draft(for: nil)), try BlessengerPolicy.exactDigest(before))
    XCTAssertEqual(removed.blessenger!.groups, [group])
    XCTAssertEqual(removed.chats, initial.chats)
    XCTAssertEqual(removed.voices.map(\.id), [second.id])
    XCTAssertTrue(removed.voiceVersions.contains(firstVoice))
    XCTAssertThrowsError(try BlessengerPolicy.resolve(host: nil, draft: before, state: removed, frozen: false),
      "A changed recipient must not silently become ordinary chat or a reduced group")
    model.removeContact(first.id) // deliberately remove the stale To chip
    try await model.flushDraft()
    let readdressed = try await store.blessengerSnapshot()
    XCTAssertEqual(model.draft.text.utf8.map { $0 }, before.text.utf8.map { $0 })
    XCTAssertEqual(try BlessengerPolicy.resolve(host: nil, draft: model.draft, state: readdressed, frozen: false), [contacts[1]])
    XCTAssertEqual(readdressed.chats, initial.chats, "Neither action may send or create a case")
    try await model.shutdown()
  }
}
