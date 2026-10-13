import BoomCore
import Foundation
import XCTest
@testable import Boom

final class PagedTextFileStoreTests: XCTestCase {
  private func queued<T: Sendable>(_ queue: DispatchQueue,
    _ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try body() }) }
    }
  }
  private func root() -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("public-file-pages-" + UUID().uuidString)
    addTeardownBlock { try FileManager.default.removeItem(at: path) }
    return path
  }
  func testPlainAppendPrefixAndExactLocatorsSurviveReopen() async throws {
    let root = root(), queue = DispatchQueue(label: "public-file-pages"), owner = UUID(), storeID = UUID(), document = UUID()
    try await queued(queue) {
      let store = try PagedTextFileStore(root: root, ownerID: owner, storeID: storeID, queue: queue)
      let provider = try store.documentPages(document)
      let first = Data("Cafe\u{301} 👩🏽‍💻\r\npublic first page".utf8)
      let a = try provider.writeNew(ownerID: owner, documentID: document, kind: .text, bytes: first)
      let path = root.appendingPathComponent("documents/" + document.uuidString.lowercased() + "/pages")
      let before = try Data(contentsOf: path)
      XCTAssertNotNil(before.range(of: first))
      let second = Data(repeating: 0x62, count: 65_536)
      let b = try provider.writeNew(ownerID: owner, documentID: document, kind: .text, bytes: second)
      XCTAssertEqual(a.storeID, storeID); XCTAssertEqual(b.storeID, storeID)
      XCTAssertEqual(b.offset, UInt64(before.count)); XCTAssertEqual(b.bytes, 65_536)
      XCTAssertEqual(Data(try Data(contentsOf: path).prefix(before.count)), before)
      try store.close()
      let reopened = try PagedTextFileStore(root: root, ownerID: owner, storeID: storeID, queue: queue)
      XCTAssertEqual(try reopened.readPage(documentID: document, kind: .text,
        page: PagedTextPageRef(locator: a, digest: Digest.sha256(first)), maximumBytes: 65_536), first)
      XCTAssertEqual(try reopened.readPage(documentID: document, kind: .text,
        page: PagedTextPageRef(locator: b, digest: Digest.sha256(second)), maximumBytes: 65_536), second)
      XCTAssertEqual(try reopened.statistics().pageReads, 2)
      try reopened.close()
    }
  }
  func testOwnerKindStoreExtentDigestAndPageBoundsAreRealRefusals() async throws {
    let root = root(), queue = DispatchQueue(label: "public-file-page-refusals"), owner = UUID(), storeID = UUID(), document = UUID()
    try await queued(queue) {
      let store = try PagedTextFileStore(root: root, ownerID: owner, storeID: storeID, queue: queue)
      let provider = try store.documentPages(document), data = Data("public bounded page".utf8)
      let locator = try provider.writeNew(ownerID: owner, documentID: document, kind: .text, bytes: data)
      let page = PagedTextPageRef(locator: locator, digest: Digest.sha256(data))
      XCTAssertThrowsError(try provider.read(ownerID: UUID(), documentID: document, kind: .text, page: page, maximumPlaintextBytes: 65_536))
      XCTAssertThrowsError(try provider.read(ownerID: owner, documentID: UUID(), kind: .text, page: page, maximumPlaintextBytes: 65_536))
      XCTAssertThrowsError(try store.readPage(documentID: document, kind: .index, page: page, maximumBytes: 16_384))
      let foreign = PagedTextPageLocator(storeID: UUID(), offset: locator.offset, bytes: locator.bytes)
      XCTAssertThrowsError(try store.readPage(documentID: document, kind: .text,
        page: PagedTextPageRef(locator: foreign, digest: page.digest), maximumBytes: 65_536))
      XCTAssertThrowsError(try store.appendPage(documentID: document, kind: .text, bytes: Data(repeating: 0x61, count: 65_537)))
      XCTAssertThrowsError(try store.appendPage(documentID: document, kind: .index, bytes: Data(repeating: 0x61, count: 16_385)))
      let path = root.appendingPathComponent("documents/" + document.uuidString.lowercased() + "/pages")
      var bytes = try Data(contentsOf: path); bytes[bytes.count - 1] ^= 1
      try bytes.write(to: path)
      XCTAssertThrowsError(try store.readPage(documentID: document, kind: .text, page: page, maximumBytes: 65_536))
      try bytes.prefix(11).write(to: path)
      XCTAssertThrowsError(try store.readPage(documentID: document, kind: .text, page: page, maximumBytes: 65_536))
      try store.close()
    }
  }
  func testMetadataAtomicReplacementAndQueueCloseAdmission() async throws {
    let root = root(), queue = DispatchQueue(label: "public-file-metadata"), owner = UUID(), storeID = UUID()
    let store = try await queued(queue) { try PagedTextFileStore(root: root, ownerID: owner, storeID: storeID, queue: queue) }
    XCTAssertThrowsError(try store.statistics(), "File operations must stay on their actual queue")
    try await queued(queue) {
      XCTAssertNil(try store.readMetadata(relativePath: "workspace.json", maximumBytes: 16))
      try store.writeMetadata(relativePath: "workspace.json", bytes: Data("first".utf8))
      try store.writeMetadata(relativePath: "workspace.json", bytes: Data("second".utf8))
      XCTAssertEqual(try store.readMetadata(relativePath: "workspace.json", maximumBytes: 16), Data("second".utf8))
      XCTAssertThrowsError(try store.readMetadata(relativePath: "workspace.json", maximumBytes: 5))
      XCTAssertThrowsError(try store.readMetadata(relativePath: "../outside", maximumBytes: 16))
      XCTAssertThrowsError(try store.writeMetadata(relativePath: "/outside", bytes: Data()))
      try store.close()
      XCTAssertThrowsError(try store.statistics())
    }
  }
}
