import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

final class PagedTextVaultTests: XCTestCase {
  private func adapter(owner: UUID, key: SymmetricKey) throws -> PagedTextVaultAdapter {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-paged-vault-" + UUID().uuidString)
    let vault = try Vault(root: root, testKey: key)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return try PagedTextVaultAdapter(vault: vault, ownerID: owner)
  }
  func testExactPageBytesFreshNonceAndIdentityAuthentication() async throws {
    let owner = UUID(), document = UUID(), container = UUID(), record = UUID()
    let key = SymmetricKey(size: .bits256)
    let adapter = try adapter(owner: owner, key: key)
    let bytes = Data("Cafe\u{301} 👩🏽‍💻\r\npublic page\0".utf8)
    let binding = try PagedTextPageBinding(ownerID: owner, documentID: document, containerID: container,
      recordID: record, offset: 42, kind: .text, plaintextBytes: bytes.count)
    let sealed = try await adapter.seal(bytes, binding: binding)
    let second = try await adapter.seal(bytes, binding: binding)
    XCTAssertNotEqual(sealed, second)
    let opened = try await adapter.open(sealed, binding: binding)
    XCTAssertEqual(opened.bytes, bytes)
    XCTAssertEqual(opened.binding, binding)

    for changed in [
      try PagedTextPageBinding(ownerID: owner, documentID: UUID(), containerID: container, recordID: record,
        offset: 42, kind: .text, plaintextBytes: bytes.count),
      try PagedTextPageBinding(ownerID: owner, documentID: document, containerID: UUID(), recordID: record,
        offset: 42, kind: .text, plaintextBytes: bytes.count),
      try PagedTextPageBinding(ownerID: owner, documentID: document, containerID: container, recordID: UUID(),
        offset: 42, kind: .text, plaintextBytes: bytes.count),
      try PagedTextPageBinding(ownerID: owner, documentID: document, containerID: container, recordID: record,
        offset: 43, kind: .text, plaintextBytes: bytes.count),
      try PagedTextPageBinding(ownerID: owner, documentID: document, containerID: container, recordID: record,
        offset: 42, kind: .index, plaintextBytes: bytes.count),
    ] {
      do { _ = try await adapter.open(sealed, binding: changed); XCTFail("Changed page identity was admitted") }
      catch {}
    }
    let foreign = try self.adapter(owner: UUID(), key: key)
    do { _ = try await foreign.open(sealed, binding: binding); XCTFail("Foreign owner was admitted") }
    catch {}
    var corrupted = sealed
    corrupted[corrupted.count - 1] ^= 1
    do { _ = try await adapter.open(corrupted, binding: binding); XCTFail("Changed ciphertext was admitted") }
    catch {}
    do { _ = try await adapter.open(Data(sealed.dropLast()), binding: binding); XCTFail("Truncated page was admitted") }
    catch {}
  }
  func testPageWorkingBoundsRemainIndependentOfDocumentLength() async throws {
    let owner = UUID(), adapter = try self.adapter(owner: owner, key: SymmetricKey(size: .bits256))
    let maximum = Data(repeating: 0x61, count: PagedTextPageBinding.Kind.text.maximumBytes)
    let binding = try PagedTextPageBinding(ownerID: owner, documentID: UUID(), containerID: UUID(), recordID: UUID(),
      offset: 0, kind: .text, plaintextBytes: maximum.count)
    let sealed = try await adapter.seal(maximum, binding: binding)
    XCTAssertEqual(sealed.count, maximum.count + 28)
    let opened = try await adapter.open(sealed, binding: binding)
    XCTAssertEqual(opened.bytes, maximum)
    XCTAssertThrowsError(try PagedTextPageBinding(ownerID: owner, documentID: UUID(), containerID: UUID(), recordID: UUID(),
      offset: 0, kind: .index, plaintextBytes: 16_385))
    XCTAssertThrowsError(try PagedTextPageBinding(ownerID: owner, documentID: UUID(), containerID: UUID(), recordID: UUID(),
      offset: 0, kind: .text, plaintextBytes: 65_537))
    do { _ = try await adapter.seal(Data(maximum.dropLast()), binding: binding); XCTFail("Wrong plaintext length was admitted") }
    catch {}
  }
}
