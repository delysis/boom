// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "BoomCore", platforms: [.macOS(.v15)], products: [.library(name: "BoomCore", targets: ["BoomCore"])],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
  ],
  targets: [
    .target(name: "BoomCore", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
    .testTarget(name: "BoomCoreTests", dependencies: ["BoomCore"]),
  ], swiftLanguageModes: [.v5])
