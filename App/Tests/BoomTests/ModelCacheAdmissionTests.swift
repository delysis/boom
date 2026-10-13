import BoomCore
import XCTest
@testable import Boom

final class ModelCacheAdmissionTests: XCTestCase {
  func testScopedPublicSnapshotLinksRemainAcceptedAndEscapesAreRefused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-cache-admission-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appendingPathComponent("models--public--fixture")
    let snapshot = repository.appendingPathComponent("snapshots/" + String(repeating: "a", count: 40))
    let blobs = repository.appendingPathComponent("blobs")
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: false)
    var files: [ModelFile] = []
    // This is a file-admission fixture, not a runnable Gemma checkpoint.
    for name in ["config.json", "tokenizer.json", "tokenizer_config.json", "generation_config.json", "processor_config.json", "model.safetensors"] {
      let bytes = name.hasSuffix(".json") ? Data("{}".utf8) : Data(repeating: 0x31, count: 32)
      let blob = blobs.appendingPathComponent(name)
      try bytes.write(to: blob)
      try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent(name), withDestinationURL: blob)
      files.append(ModelFile(path: name, bytes: Int64(bytes.count), sha256: Digest.sha256(bytes)))
    }
    let checkpoint = PublishedCheckpoint(purpose: .consultation, repository: "public/fixture",
      revision: String(repeating: "a", count: 40), files: files)
    XCTAssertEqual(try ModelPacks.verifyPublished(snapshot, checkpoint: checkpoint).weightBytes, 32)
    let outside = root.appendingPathComponent("outside.json")
    try Data("{}".utf8).write(to: outside)
    let link = snapshot.appendingPathComponent("config.json")
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    XCTAssertThrowsError(try ModelPacks.verifyPublished(snapshot, checkpoint: checkpoint))
  }

  private func qualifyOfficialCache(_ purpose: ModelPurpose) throws {
    guard ProcessInfo.processInfo.environment["BLOOM_QUALIFY_OFFICIAL_CACHE"] == "1" else {
      throw XCTSkip("Explicit qualification reads only the already-cached, catalog-pinned public checkpoint; it never downloads weights.")
    }
    let directory = try XCTUnwrap(ModelPacks.officialCached(purpose))
    XCTAssertTrue(try directory.appendingPathComponent("config.json")
      .resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    let specification = try ModelPacks.entry(purpose).manifest
    let admission: ModelPacks.Admission
    if purpose == .writing { admission = try ModelPacks.admission(directory) }
    else { admission = try ModelPacks.admission(directory, purpose: purpose) }
    XCTAssertEqual(admission.purpose, purpose)
    XCTAssertEqual(admission.kind.rawValue, ModelPacks.Admission.Kind.officialCheckpoint.rawValue)
    XCTAssertEqual(admission.identity, specification.upstreamRepository + "@" + specification.upstreamRevision)
    XCTAssertEqual(admission.weightBytes, specification.upstreamFiles.filter { $0.path.hasSuffix(".safetensors") }
      .reduce(UInt64(0)) { $0 + UInt64($1.bytes) })
    XCTAssertEqual(admission.directory.standardizedFileURL, directory.standardizedFileURL)
  }
  func testWritingOfficialCacheUsesItsAdmittedBlobLinks() throws {
    try qualifyOfficialCache(.writing)
  }
  func testConsultationOfficialCacheUsesItsAdmittedBlobLinks() throws {
    try qualifyOfficialCache(.consultation)
  }
}
