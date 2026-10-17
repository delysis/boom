// swift-tools-version: 6.2
import Foundation
import PackageDescription

let productRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent()
let buildURL = productRoot.appendingPathComponent(".build-support/RustProductBuild.json")
let libraryDirectory: String
let rustArchiveSettings: [CSetting]
let productSwiftSettings: [SwiftSetting]
if FileManager.default.fileExists(atPath: buildURL.path) {
  let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: buildURL))
  libraryDirectory = config["libraryDirectory"]!
  productSwiftSettings = config["edition"] == "blessenger" ? [.define("BLESSENGER")] : []
  guard let hash = config["librarySHA256"], hash.utf8.count == 64,
    hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
    fatalError("Rebuild with scripts/build-macos.sh to record the Rust archive hash.")
  }
  // A changed external static archive is not otherwise a SwiftPM build input.
  // Its digest changes the C shim's command and forces the native product to
  // relink even when no Swift source changed. The build receipt retains it.
  rustArchiveSettings = [.define("BLOOM_RUST_ARCHIVE_SHA256_" + hash)]
} else {
  libraryDirectory = productRoot.appendingPathComponent("target/release").path
  rustArchiveSettings = []
  productSwiftSettings = []
}
let nativeLinkURL = productRoot.appendingPathComponent(".build-support/RustNativeLink.json")
let nativeLinkFlags: [String]
if FileManager.default.fileExists(atPath: nativeLinkURL.path) {
  let bytes = try Data(contentsOf: nativeLinkURL)
  nativeLinkFlags = try JSONDecoder().decode([String].self, from: bytes)
  precondition(!nativeLinkFlags.isEmpty && nativeLinkFlags.count <= 128)
} else {
  // Dependency resolution needs no native library. The build script requires
  // rustc's actual native-static-libs receipt before invoking swift build.
  nativeLinkFlags = []
}
let package = Package(
  name: "Boom",
  platforms: [.macOS(.v15)],
  products: [.executable(name: "Boom", targets: ["Boom"]),
    .executable(name: "BloomPackBuilder", targets: ["BloomPackBuilder"])],
  dependencies: [
    .package(path: "../Core"),
    .package(path: "../.deps/MLXSwiftLM", traits: []),
    .package(path: "../.deps/Qwen3TTS"),
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.4"),
    .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.11.0"),
  ],
  targets: [
    .executableTarget(name: "BloomPackBuilder", dependencies: [
      .product(name: "MLXLMCommon", package: "MLXSwiftLM"),
      .product(name: "MLXVLM", package: "MLXSwiftLM"),
      .product(name: "MLXHuggingFace", package: "MLXSwiftLM"),
      .product(name: "Tokenizers", package: "swift-transformers"),
    ], resources: [.process("Resources")]),
    .target(name: "CAttachment", publicHeadersPath: "include", cSettings: rustArchiveSettings),
    .executableTarget(
      name: "Boom",
      dependencies: [
        .product(name: "BoomCore", package: "core"),
        "CAttachment",
        .product(name: "MLXLMCommon", package: "MLXSwiftLM"),
        .product(name: "MLXVLM", package: "MLXSwiftLM"),
        .product(name: "MLXHuggingFace", package: "MLXSwiftLM"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "Qwen3TTS", package: "Qwen3TTS"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "Hub", package: "swift-transformers"),
      ],
      resources: [.process("Resources")],
      swiftSettings: productSwiftSettings,
      linkerSettings: [
        .unsafeFlags(
          [
            "-L" + libraryDirectory,
            "-lboom_attachment_ffi",
          ] + nativeLinkFlags.flatMap { ["-Xlinker", $0] }),
        .linkedLibrary("bsm", .when(platforms: [.macOS])),
        .linkedFramework("AppKit"), .linkedFramework("Security"),
        .linkedFramework("SystemConfiguration"),
        .linkedFramework("AVFoundation"), .linkedFramework("Speech"), .linkedFramework("CoreML"),
      ]),
    .testTarget(name: "BoomTests", dependencies: ["Boom"], resources: [.copy("Fixtures")]),
  ], swiftLanguageModes: [.v5]
)
