import BoomCore
import CryptoKit
import Foundation
import XCTest
@testable import Boom

final class PagedTextContainerTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-paged-container-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  func testAppendLocatorsReopenAndDoNotReplacePriorCiphertext() async throws {
    let root = try root(), key = SymmetricKey(size: .bits256), owner = UUID(), document = UUID()
    let vault = try Vault(root: root, testKey: key)
    let store = try PagedTextContainerStore(vault: vault, ownerID: owner, documentID: document)
    let first = Data("Cafe\u{301} 👩🏽‍💻\r\npublic first page".utf8)
    let a = try store.writeNew(ownerID: owner, documentID: document, kind: .text, bytes: first)
    let url = root.appendingPathComponent("paged-text-v1/" + document.uuidString + "/" + a.containerID.uuidString + ".sealed")
    let before = try Data(contentsOf: url)
    XCTAssertNil(before.range(of: first))
    let second = Data(repeating: 0x62, count: 65_536)
    let b = try store.writeNew(ownerID: owner, documentID: document, kind: .text, bytes: second)
    try store.synchronizeNewRecords()
    XCTAssertEqual(a.containerID, b.containerID)
    XCTAssertGreaterThan(b.offset, a.offset)
    XCTAssertNotEqual(a.recordID, b.recordID)
    let after = try Data(contentsOf: url)
    XCTAssertEqual(Data(after.prefix(before.count)), before)
    let reopened = try PagedTextContainerStore(vault: Vault(root: root, testKey: key), ownerID: owner, documentID: document)
    XCTAssertEqual(try reopened.read(ownerID: owner, documentID: document, kind: .text,
      page: PagedTextPageRef(locator: a, digest: Digest.sha256(first)), maximumPlaintextBytes: 65_536), first)
    XCTAssertEqual(try reopened.read(ownerID: owner, documentID: document, kind: .text,
      page: PagedTextPageRef(locator: b, digest: Digest.sha256(second)), maximumPlaintextBytes: 65_536), second)
    // Root/digest/recovery admission is still the engine's separate obligation.
    let count = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count
    XCTAssertEqual(count, 1)
  }
  func testWrongIdentityFramingTamperAndOversizedInputFailClosed() async throws {
    let root = try root(), owner = UUID(), document = UUID(), key = SymmetricKey(size: .bits256)
    let vault = try Vault(root: root, testKey: key)
    let store = try PagedTextContainerStore(vault: vault, ownerID: owner, documentID: document)
    let data = Data("public bounded page".utf8)
    let locator = try store.writeNew(ownerID: owner, documentID: document, kind: .text, bytes: data)
    let page = PagedTextPageRef(locator: locator, digest: Digest.sha256(data))
    XCTAssertThrowsError(try store.read(ownerID: UUID(), documentID: document, kind: .text,
      page: page, maximumPlaintextBytes: 65_536))
    XCTAssertThrowsError(try store.read(ownerID: owner, documentID: document, kind: .index,
      page: page, maximumPlaintextBytes: 16_384))
    let wrong = PagedTextPageLocator(containerID: locator.containerID, recordID: locator.recordID,
      offset: locator.offset + 1, ciphertextBytes: locator.ciphertextBytes)
    XCTAssertThrowsError(try store.read(ownerID: owner, documentID: document, kind: .text,
      page: PagedTextPageRef(locator: wrong, digest: page.digest), maximumPlaintextBytes: 65_536))
    XCTAssertThrowsError(try store.writeNew(ownerID: owner, documentID: document, kind: .text,
      bytes: Data(repeating: 0x61, count: 65_537)))
    let url = root.appendingPathComponent("paged-text-v1/" + document.uuidString + "/" + locator.containerID.uuidString + ".sealed")
    var bytes = try Data(contentsOf: url)
    bytes[bytes.count - 1] ^= 1
    try bytes.write(to: url)
    XCTAssertThrowsError(try store.read(ownerID: owner, documentID: document, kind: .text,
      page: page, maximumPlaintextBytes: 65_536))
  }
  func testReplacedAppendContainerCannotPublishOrAcceptAnotherAppend() async throws {
    let root = try root(), owner = UUID(), document = UUID()
    let store = try PagedTextContainerStore(vault: Vault(root: root, testKey: SymmetricKey(size: .bits256)),
      ownerID: owner, documentID: document)
    let locator = try store.writeNew(ownerID: owner, documentID: document, kind: .text, bytes: Data("public retained page".utf8))
    let directory = root.appendingPathComponent("paged-text-v1/" + document.uuidString)
    let path = directory.appendingPathComponent(locator.containerID.uuidString + ".sealed")
    let retained = directory.appendingPathComponent("public-retained-original.sealed")
    try FileManager.default.moveItem(at: path, to: retained)
    let replacement = Data("public unrelated replacement".utf8)
    try replacement.write(to: path, options: .withoutOverwriting)
    XCTAssertThrowsError(try store.synchronizeNewRecords())
    XCTAssertThrowsError(try store.writeNew(ownerID: owner, documentID: document, kind: .text, bytes: Data("x".utf8)))
    XCTAssertEqual(try Data(contentsOf: path), replacement)
    XCTAssertGreaterThan(try Data(contentsOf: retained).count, 28)
  }
}
