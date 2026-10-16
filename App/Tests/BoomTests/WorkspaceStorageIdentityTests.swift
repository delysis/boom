import Foundation
import XCTest
@testable import Boom

final class WorkspaceStorageIdentityTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-storage-identity-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }

  func testFileIdentitySurvivesReopeningWithoutReplacingBytes() async throws {
    let root = try root(), store = try WorkspaceStore(rootOverride: root)
    let first = try await store.storageIdentity()
    let path = store.root.appendingPathComponent("identity.json"), before = try Data(contentsOf: path)
    let reopened = try WorkspaceStore(rootOverride: root), second = try await reopened.storageIdentity()
    XCTAssertEqual(first.ownerID, second.ownerID); XCTAssertEqual(first.storeID, second.storeID)
    XCTAssertEqual(try Data(contentsOf: path), before)
    let value = try JSONDecoder().decode(WorkspaceStorageIdentity.self, from: before)
    XCTAssertEqual(value.schema, 1); XCTAssertEqual(value.ownerID, first.ownerID)
    XCTAssertEqual(value.storeID, first.storeID)
  }

  func testMalformedOrZeroIdentityIsNotReplaced() async throws {
    let root = try root(), store = try WorkspaceStore(rootOverride: root)
    _ = try await store.storageIdentity()
    let path = store.root.appendingPathComponent("identity.json")
    for bytes in [Data("invalid identity".utf8), Data("{\"schema\":1,\"ownerID\":\"00000000-0000-0000-0000-000000000000\",\"storeID\":\"00000000-0000-0000-0000-000000000000\"}".utf8)] {
      try bytes.write(to: path)
      do { _ = try await store.storageIdentity(); XCTFail("Invalid identity was admitted") }
      catch { XCTAssertEqual(try Data(contentsOf: path), bytes) }
    }
  }

  func testOversizedOrLinkedIdentityIsRefusedWithoutReplacingEitherFile() async throws {
    let root = try root(), store = try WorkspaceStore(rootOverride: root)
    let path = store.root.appendingPathComponent("identity.json")
    let oversized = Data(repeating: 0x20, count: 513)
    try oversized.write(to: path)
    do { _ = try await store.storageIdentity(); XCTFail("Oversized identity was admitted") }
    catch { XCTAssertEqual(try Data(contentsOf: path), oversized) }
    try FileManager.default.removeItem(at: path)
    let target = root.appendingPathComponent("original.json")
    let original = try JSONEncoder().encode(WorkspaceStorageIdentity(schema: 1, ownerID: UUID(), storeID: UUID()))
    try original.write(to: target)
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
    do { _ = try await store.storageIdentity(); XCTFail("Linked identity was admitted") }
    catch {
      XCTAssertEqual(try Data(contentsOf: target), original)
      XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path.path), target.path)
    }
  }
}
