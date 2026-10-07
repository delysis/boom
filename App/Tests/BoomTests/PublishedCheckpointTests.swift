import BoomCore
import CryptoKit
import XCTest
@testable import Boom

final class PublishedCheckpointTests: XCTestCase {
  private func fixture(_ root: URL) throws -> PublishedCheckpoint {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let files = try ["config.json", "tokenizer.json", "tokenizer_config.json", "generation_config.json", "processor_config.json", "model.safetensors"].map { name in
      let bytes = Data(("Public fixture: " + name).utf8)
      try bytes.write(to: root.appendingPathComponent(name))
      return ModelFile(path: name, bytes: Int64(bytes.count), sha256: Digest.sha256(bytes))
    }
    return PublishedCheckpoint(purpose: .writing, repository: "public-fixture/model", revision: String(repeating: "a", count: 40), files: files)
  }
  func testPublishedCatalogFitsSingleModelAdmissionAndBindsExactFiles() throws {
    for purpose in ModelPurpose.allCases {
      let checkpoint = try ModelPacks.published(purpose)
      let requirements = try ProductCore.checkpointRequirements(checkpoint)
      XCTAssertEqual(requirements.identity, checkpoint.repository + "@" + checkpoint.revision)
      XCTAssertTrue(try ProductCore.admitModelLoad(physical: 137_438_953_472, metal: 103_079_215_104,
        resident: 0, weights: requirements.weightBytes))
      let fullPrecision = try ModelPacks.entry(purpose).manifest.upstreamFiles.filter { $0.path.hasSuffix(".safetensors") }.reduce(UInt64(0)) { $0 + UInt64($1.bytes) }
      XCTAssertFalse(try ProductCore.admitModelLoad(physical: 137_438_953_472, metal: 103_079_215_104,
        resident: 0, weights: fullPrecision))
    }
  }
  func testCacheSearchReachesLaterHubAndVerifiesNativeBlobLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-public-cache-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let hub = root.appendingPathComponent("second-hub")
    let snapshot = ModelPacks.snapshot(repository: "public-fixture/model", revision: String(repeating: "a", count: 40), hub: hub)
    let checkpoint = try fixture(snapshot)
    let blobs = snapshot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("blobs")
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: false)
    for file in checkpoint.files {
      let source = snapshot.appendingPathComponent(file.path), destination = blobs.appendingPathComponent(file.sha256)
      try FileManager.default.moveItem(at: source, to: destination)
      try FileManager.default.createSymbolicLink(at: source, withDestinationURL: destination)
    }
    XCTAssertEqual(ModelPacks.cachedSnapshot(checkpoint, hubs: [root.appendingPathComponent("first-hub"), hub])?.path, snapshot.path)
    XCTAssertEqual(try ModelPacks.verifyPublished(snapshot, checkpoint: checkpoint).weightBytes,
      UInt64(checkpoint.files.last!.bytes))
    let original = try Data(contentsOf: blobs.appendingPathComponent(checkpoint.files[0].sha256))
    var changed = original; changed[0] ^= 1
    try changed.write(to: blobs.appendingPathComponent(checkpoint.files[0].sha256))
    XCTAssertThrowsError(try ModelPacks.verifyPublished(snapshot, checkpoint: checkpoint))
    XCTAssertEqual(try Data(contentsOf: blobs.appendingPathComponent(checkpoint.files[0].sha256)), changed,
      "Verification must retain corrupt evidence.")
  }
  func testIdenticalBytesOutsideSnapshotAndBlobStoreAreRejected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-public-escape-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = root.appendingPathComponent("repository/snapshots/revision")
    let checkpoint = try fixture(snapshot)
    let source = snapshot.appendingPathComponent("config.json"), outside = root.appendingPathComponent("outside.json")
    try FileManager.default.moveItem(at: source, to: outside)
    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
    XCTAssertThrowsError(try ModelPacks.verifyPublished(snapshot, checkpoint: checkpoint))
    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
  }
}
