// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "BoomCore", platforms: [.macOS(.v15)], products: [.library(name: "BoomCore", targets: ["BoomCore"])],
  targets: [
    .target(name: "BoomCore"), .testTarget(name: "BoomCoreTests", dependencies: ["BoomCore"]),
  ], swiftLanguageModes: [.v5])
