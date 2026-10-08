import BoomCore
import Foundation
import XCTest
@testable import Boom

final class ModelPickerTests: XCTestCase {
  func testNativePickerReceivesOnlyModelsAdmittedBySharedRustPolicy() throws {
    let gib: UInt64 = 1 << 30
    let candidates = [
      ModelSetupCandidate(identity: "local", purpose: .consultation, weightBytes: 8 * gib, diskBytes: 0, cached: true, rank: 1),
      ModelSetupCandidate(identity: "download", purpose: .writing, weightBytes: 4 * gib, diskBytes: 8 * gib, cached: false, rank: 0),
      ModelSetupCandidate(identity: "too-large", purpose: .consultation, weightBytes: 17 * gib, diskBytes: 0, cached: true, rank: 0),
    ]
    XCTAssertEqual(try ProductCore.modelChoices(physical: 32 * gib, metal: 24 * gib, resident: gib, disk: 0, candidates: candidates), ["local"])
    XCTAssertEqual(try ProductCore.modelChoices(physical: 32 * gib, metal: 24 * gib, resident: gib, disk: 10 * gib, candidates: candidates), ["local", "download"])
  }
  func testLMStudioDiscoveryIsBoundedToCuratedRepositoriesAndCompleteFiles() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-model-discovery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let roots = LocalModelDirectories.roots(home: home)
    XCTAssertEqual(roots.map(\.lastPathComponent), ["models", "models"])
    let checkpoint = PublishedCheckpoint(purpose: .consultation, repository: "mlx-community/public-fixture", revision: String(repeating: "a", count: 40),
      files: [ModelFile(path: "config.json", bytes: 2, sha256: String(repeating: "a", count: 64)), ModelFile(path: "model.safetensors", bytes: 3, sha256: String(repeating: "b", count: 64))])
    let folder = roots[0].appendingPathComponent(checkpoint.repository)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
    XCTAssertNil(LocalModelDirectories.cached(checkpoint, roots: roots))
    try Data([1, 2, 3]).write(to: folder.appendingPathComponent("model.safetensors"))
    XCTAssertEqual(LocalModelDirectories.cached(checkpoint, roots: roots)?.path, folder.path)
    let unrelated = PublishedCheckpoint(purpose: .consultation, repository: "other/model", revision: checkpoint.revision, files: checkpoint.files)
    XCTAssertNil(LocalModelDirectories.cached(unrelated, roots: roots))
  }
}
