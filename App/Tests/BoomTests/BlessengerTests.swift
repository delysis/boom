import BoomCore
import Darwin
import Foundation
import XCTest
@testable import Boom

final class BlessengerTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Blessenger-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
  private func store(_ root: URL) throws -> WorkspaceStore {
    try WorkspaceStore(rootOverride: root, privateSession: BlessengerKeySession { _ in Data(repeating: 0x41, count: 32) })
  }
  private var fixtureCatalog: BlessengerCatalog {
    BlessengerCatalog(sourceRevision: "owned-unit-fixture", sourceSHA256: "owned-unit-fixture", entries: [])
  }
  private func turn(_ draft: BlessengerDraft, profile: BlessengerProfile = BlessengerProfile(), history: ChatRecord? = nil) throws -> BlessengerPreparedTurn {
    let id = UUID()
    let plan = try ProductCore.prompt(voice: nil, history: history?.messages ?? [], instructions: "", context: "",
      request: draft.text, routing: [])
    let receipt = ConsultationReceipt(operationID: UUID(), seed: 7, state: .pending, model: "component-fixture-not-inference",
      voice: nil, plan: plan, sources: [], promptDigest: Digest.sha256(plan.rawPrompt), tokenIDs: [],
      stopReason: "pending", elapsedSeconds: 0, generationPolicy: nil, attemptID: UUID(), responseID: id)
    return BlessengerPreparedTurn(chatID: history?.id ?? UUID(), draft: draft, history: history, contacts: [],
      profile: profile, sourceDigests: [], context: "", responseIDs: [id], receipts: [receipt], voices: [nil], outputLimit: profile.maximumTokens)
  }
  func testNativeDraftTransferIsAtomicAndCannotRepeat() async throws {
    let root = try root(), store = try store(root)
    let initial = try await store.openBlessenger(catalog: fixtureCatalog)
    var draft = initial.blessenger!.draft(for: nil), old = draft.version
    draft.text = "  Exact case\r\n🪷 e\u{301}  "; draft.version = UUID()
    let saved = try await store.blessengerSaveDraft(draft, expectedVersion: old)
    let prepared = try turn(draft, profile: saved.blessenger!.defaultProfile)
    let admitted = try await store.blessengerAdmit(prepared)
    XCTAssertEqual(admitted.chats.count, 1)
    XCTAssertEqual(Array(admitted.chats[0].messages[0].text.utf8), Array(draft.text.utf8))
    XCTAssertEqual(admitted.chats[0].messages[1].state, .pending)
    XCTAssertTrue(admitted.blessenger!.draft(for: nil).text.isEmpty)
    do { _ = try await store.blessengerAdmit(prepared); XCTFail("Repeated admission succeeded") } catch {}
    let final = try await store.blessengerSnapshot()
    XCTAssertEqual(final.chats.count, 1)
    let ciphertext = try Data(contentsOf: root.appendingPathComponent("workspace.json"))
    XCTAssertNil(ciphertext.range(of: Data(draft.text.utf8)))
    try await store.releaseExclusiveWorkspace()
  }
  func testInterveningDraftAndProfileEditsRefuseWithoutCreatingChat() async throws {
    let store = try store(root()), initial = try await store.openBlessenger(catalog: fixtureCatalog)
    var draft = initial.blessenger!.draft(for: nil)
    let old = draft.version; draft.version = UUID(); draft.text = "Initial question"
    let first = try await store.blessengerSaveDraft(draft, expectedVersion: old)
    let captured = try turn(draft, profile: first.blessenger!.defaultProfile)
    let beforeTyping = draft.version; draft.version = UUID(); draft.text += " and more typing"
    _ = try await store.blessengerSaveDraft(draft, expectedVersion: beforeTyping)
    do { _ = try await store.blessengerAdmit(captured); XCTFail("Stale draft admitted") } catch {}
    let current = try await store.blessengerSnapshot()
    XCTAssertTrue(current.chats.isEmpty); XCTAssertEqual(current.blessenger!.draft(for: nil).text, draft.text)
    let capturedProfile = try turn(draft, profile: current.blessenger!.defaultProfile)
    _ = try await store.blessengerTransaction { _, product in product.defaultProfile.id = UUID() }
    do { _ = try await store.blessengerAdmit(capturedProfile); XCTFail("Stale profile admitted") } catch {}
    let final = try await store.blessengerSnapshot()
    XCTAssertTrue(final.chats.isEmpty)
    try await store.releaseExclusiveWorkspace()
  }
  func testFirstCallerTurnDoesNotConsumeTypedDraft() async throws {
    let store = try store(root()), initial = try await store.openBlessenger(catalog: fixtureCatalog)
    var draft = initial.blessenger!.draft(for: nil), prior = draft.version
    draft.version = UUID(); draft.text = "Unsent typed note must remain"
    let state = try await store.blessengerSaveDraft(draft, expectedVersion: prior)
    let route = try await store.blessengerBeginCall(selection: nil, expectedDraftVersion: draft.version)
    let original = Data("owned component attachment, not real caller audio".utf8)
    let record = AttachmentRecord(id: UUID(), name: "Owned call fixture", rootDigest: Digest.sha256(original),
      text: "Public fixture", coverage: "component fixture", transform: nil, presentation: .text)
    let imported = AttachmentImport(record: record, receipt: Data("fixture receipt".utf8), original: original)
    let caller = try await store.blessengerCallerTurn(imported, callID: route.id, epoch: 1, flag: CancellationFlag())
    var prepared = try turn(caller.draft, profile: route.profile)
    prepared.caller = caller
    let admitted = try await store.blessengerAdmit(prepared)
    XCTAssertEqual(admitted.blessenger!.draft(for: nil), draft)
    XCTAssertEqual(admitted.chats.count, state.chats.count + 1)
    XCTAssertEqual(admitted.chats[0].messages[0].directAttachments, [record.id])
    await store.blessengerEndCall(route.id)
    do { _ = try await store.blessengerCallerTurn(imported, callID: route.id, epoch: 2, flag: CancellationFlag()); XCTFail("Ended call admitted audio") } catch {}
    try await store.releaseExclusiveWorkspace()
  }
  func testExclusiveWorkspacePrecedesAnotherCredentialRead() async throws {
    let root = try root(), first = try store(root)
    let counter = ReadCounter()
    XCTAssertThrowsError(try WorkspaceStore(rootOverride: root, privateSession: BlessengerKeySession { _ in
      counter.increment(); return Data(repeating: 0x41, count: 32)
    }))
    XCTAssertEqual(counter.value, 0)
    try await first.releaseExclusiveWorkspace()
  }
  func testCredentialFailureIsCachedAndNeverCreatesPlaintext() throws {
    let counter = ReadCounter()
    let session = BlessengerKeySession { _ in counter.increment(); throw BoomError.denied("Owned denial fixture") }
    XCTAssertThrowsError(try session.cipher(existingRecords: true))
    XCTAssertThrowsError(try session.cipher(existingRecords: false))
    XCTAssertEqual(counter.value, 1)
  }
  func testSealedKVRangeReadChargesEveryAuthenticationTag() throws {
    let file = try root().appendingPathComponent("owned-kv")
    let fd = Darwin.open(file.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, mode_t(0o600))
    XCTAssertGreaterThanOrEqual(fd, 0); guard fd >= 0 else { return }
    defer { _ = Darwin.close(fd) }
    let source = Data((0..<150_001).map { UInt8(truncatingIfNeeded: $0 * 37) })
    let cipher = try RecordCipher(key: Data(repeating: 9, count: 32))
    let writer = SealedBlockWriter(fd: fd, total: UInt64(source.count), binding: "owned-file", cipher: cipher) { _ in }
    try source.withUnsafeBytes { bytes in
      try writer.append(bytes.baseAddress!, count: 50_000)
      try writer.append(bytes.baseAddress!.advanced(by: 50_000), count: bytes.count - 50_000)
    }
    try writer.finish()
    XCTAssertEqual(writer.physical, UInt64(source.count + 3 * RecordCipher.overhead))
    for range in [0..<1, 65530..<65550, 130000..<150001, 0..<150001] {
      let recovered = try SealedBlockWriter.read(fd, start: UInt64(range.lowerBound), count: range.count,
        total: UInt64(source.count), binding: "owned-file", cipher: cipher)
      XCTAssertEqual(recovered, source.subdata(in: range))
    }
    XCTAssertThrowsError(try SealedBlockWriter.read(fd, start: 0, count: 1,
      total: UInt64(source.count), binding: "other-file", cipher: cipher))
    var corrupt: UInt8 = 0
    XCTAssertEqual(pread(fd, &corrupt, 1, 50), 1); corrupt ^= 1; XCTAssertEqual(pwrite(fd, &corrupt, 1, 50), 1)
    XCTAssertThrowsError(try SealedBlockWriter.read(fd, start: 0, count: 1,
      total: UInt64(source.count), binding: "owned-file", cipher: cipher))
  }
}
private final class ReadCounter: @unchecked Sendable {
  private let lock = NSLock(); private var count = 0
  var value: Int { lock.lock(); defer { lock.unlock() }; return count }
  func increment() { lock.lock(); count += 1; lock.unlock() }
}
