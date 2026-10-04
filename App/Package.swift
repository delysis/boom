// swift-tools-version: 6.2
import Foundation
import PackageDescription

let productRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent()
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
  products: [.executable(name: "Boom", targets: ["Boom"])],
  dependencies: [
    .package(path: "../Core"),
    .package(path: "../.deps/CoreML-LLM"),
    .package(path: "../.deps/MLXSwiftLM", traits: []),
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.4"),
    .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.11.0"),
  ],
  targets: [
    .target(name: "CAttachment", publicHeadersPath: "include"),
    .executableTarget(
      name: "Boom",
      dependencies: [
        .product(name: "BoomCore", package: "core"),
        .product(name: "CoreMLLLM", package: "coreml-llm"), "CAttachment",
        .product(name: "MLXLMCommon", package: "MLXSwiftLM"),
        .product(name: "MLXVLM", package: "MLXSwiftLM"),
        .product(name: "MLXHuggingFace", package: "MLXSwiftLM"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ],
      linkerSettings: [
        .unsafeFlags(
          [
            "-L" + productRoot.appendingPathComponent("RustBridge/target/release").path,
            "-lboom_attachment_ffi",
          ] + nativeLinkFlags.flatMap { ["-Xlinker", $0] }),
        .linkedFramework("AppKit"), .linkedFramework("Security"),
        .linkedFramework("SystemConfiguration"), .linkedFramework("CoreML"),
        .linkedFramework("AVFoundation"), .linkedFramework("Speech"),
      ]),
    .testTarget(name: "BoomTests", dependencies: ["Boom"]),
  ], swiftLanguageModes: [.v5]
)
