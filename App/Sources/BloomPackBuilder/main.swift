import CryptoKit
import Foundation
import MLXLMCommon
import MLXVLM

/// Developer-only conversion. Never linked into Bloom's executable.
@main enum PackBuilder {
  struct File: Codable { let path: String; let bytes: Int64; let sha256: String }
  struct Manifest: Codable {
    let schema: Int
    let purpose: String
    let upstreamRepository: String
    let upstreamRevision: String
    let upstreamFiles: [File]
    let runtimeRevision: String
    let bits: Int
    let groupSize: Int
    let calibration: String
    let files: [File]
  }
  static func inventory(_ directory: URL, resolveLinks: Bool) throws -> [File] {
    try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { file in
        let target = resolveLinks ? URL(fileURLWithPath: file.resolvingSymlinksInPath().path) : file
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize else {
          throw NSError(domain: "BloomPack", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected pack file: \(file.lastPathComponent)"])
        }
        let handle = try FileHandle(forReadingFrom: target); defer { try? handle.close() }
        var digest = SHA256(); var count = 0
        while let data = try handle.read(upToCount: 4_194_304), !data.isEmpty {
          digest.update(data: data); count += data.count
        }
        guard count == bytes else { throw NSError(domain: "BloomPack", code: 2) }
        return File(path: file.lastPathComponent, bytes: Int64(count),
          sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
      }
  }
  static func main() async throws {
    let args = CommandLine.arguments
    if args.count > 1, args[1] == "--input-packaging-probe" {
      try await InputPackagingProbe.run(args); return
    }
    if args.count > 1, args[1] == "--prefill-kernel-probe" {
      try PrefillKernelProbe.run(args); return
    }
    let sealOnly = args.count > 1 && args[1].hasSuffix("-seal")
    let purpose = args.count > 1 ? args[1].replacingOccurrences(of: "-seal", with: "") : ""
    guard args.count == 6, ["consultation", "writing"].contains(purpose),
      args[2].hasPrefix("/"), args[3].hasPrefix("/"),
      args[5].range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
      throw NSError(domain: "BloomPack", code: 3, userInfo: [NSLocalizedDescriptionKey:
        "BloomPackBuilder consultation|writing ABSOLUTE_SOURCE NEW_OUTPUT UPSTREAM_REPOSITORY REVISION"])
    }
    let source = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
    guard FileManager.default.fileExists(atPath: output.path) == sealOnly else { throw NSError(domain: "BloomPack", code: 4) }
    let expected = purpose == "consultation" ? "google/gemma-4-12B-it-qat-q4_0-unquantized" : "google/gemma-4-12B"
    guard args[4] == expected, source.lastPathComponent == args[5] else { throw NSError(domain: "BloomPack", code: 5) }
    let upstream = try inventory(source, resolveLinks: true)
    let card = try String(contentsOf: source.appendingPathComponent("README.md"), encoding: .utf8)
    guard card.contains("license: apache-2.0") else { throw NSError(domain: "BloomPack", code: 6) }
    if !sealOnly {
    let materialized = output.deletingLastPathComponent().appendingPathComponent(".conversion-input-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: materialized, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: materialized) }
    for file in upstream {
      let original = source.appendingPathComponent(file.path).resolvingSymlinksInPath()
      let local = materialized.appendingPathComponent(file.path)
      if file.path.hasSuffix(".safetensors") { try FileManager.default.linkItem(at: original, to: local) }
      else { try FileManager.default.copyItem(at: original, to: local) }
    }
    let config = try JSONDecoder().decode(Gemma4UnifiedConfiguration.self,
      from: Data(contentsOf: source.appendingPathComponent("config.json")))
    let model = Gemma4Unified(config)
    let calibration: ModelConversionQuantizationCalibration = purpose == "consultation" ? .q4Zero : .standard
    _ = try convert(modelDirectory: materialized, model: model, to: output,
      options: ModelConversionOptions(bits: 4, groupSize: 32, calibration: calibration,
        maxShardSize: 1_073_741_824), progressHandler: { print($0) })
    for file in upstream where file.path.lowercased().hasPrefix("license") || file.path.lowercased().hasPrefix("notice") {
      let target = output.appendingPathComponent(file.path)
      if !FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.copyItem(at: source.appendingPathComponent(file.path).resolvingSymlinksInPath(), to: target)
      }
    }
    }
    guard let license = Bundle.module.url(forResource: "LICENSE-Gemma", withExtension: "txt") else { throw NSError(domain: "BloomPack", code: 7) }
    if !sealOnly { try FileManager.default.copyItem(at: license, to: output.appendingPathComponent("LICENSE.txt")) }
    try Data(("Gemma 4 12B weights by Google DeepMind, Apache-2.0. "
      + "Modified by georgewalker: converted into MLX affine 4-bit, group 32 safetensors. "
      + "Original checkpoint: " + args[4] + " at " + args[5]
      + "\nLicense source: https://ai.google.dev/gemma/apache_2\n").utf8)
      .write(to: output.appendingPathComponent("NOTICE.txt"))
    if !sealOnly { try FileManager.default.copyItem(at: source.appendingPathComponent("README.md").resolvingSymlinksInPath(),
      to: output.appendingPathComponent("UPSTREAM-MODEL-CARD.md")) }
    try Data(("---\nlicense: apache-2.0\nlibrary_name: mlx\nbase_model: " + args[4]
      + "\ntags:\n- gemma4\n- mlx\n- bloom\n---\n# Bloom " + purpose + " pack\n\n"
      + "Official Google Gemma 4 12B converted to MLX affine 4-bit, group 32. "
      + "Immutable upstream and runtime revisions, source hashes and output hashes are in bloom-model.json. "
      + "Conversion modifies weights and configuration; upstream attribution is retained in UPSTREAM-MODEL-CARD.md and NOTICE.txt.\n\n"
      + "This is a weights and configuration repository. It contains no Bloom application source or user data. "
      + "32 GB MacBook performance and distribution qualification remain open.\n").utf8)
      .write(to: output.appendingPathComponent("README.md"), options: .atomic)
    let manifest = Manifest(schema: 1, purpose: purpose, upstreamRepository: args[4], upstreamRevision: args[5],
      upstreamFiles: upstream, runtimeRevision: "9afc3b55f75a0d41a3d0c11330b9df6a036d24e4",
      bits: 4, groupSize: 32, calibration: purpose == "consultation" ? "q4_0" : "standard", files: try inventory(output, resolveLinks: false).filter { $0.path != "bloom-model.json" })
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(manifest)
    try data.write(to: output.appendingPathComponent("bloom-model.json"), options: .atomic)
    print("Manifest SHA256: " + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
  }
}
