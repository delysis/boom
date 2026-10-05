#!/usr/bin/env swift
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 5 else {
  fatalError(
    "usage: collect-notices.swift PRODUCT_ROOT CARGO_METADATA OUTPUT_DIRECTORY INVENTORY_JSON")
}
let root = URL(fileURLWithPath: args[1])
let destination = URL(fileURLWithPath: args[3])
let fm = FileManager.default
let object =
  try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2])))
  as? [String: Any]
guard let packages = object?["packages"] as? [[String: Any]] else {
  fatalError("Missing cargo package metadata")
}
struct Source {
  let name: String
  let directory: URL
  let license: String
  let explicit: URL?
}
var sources = packages.compactMap { package -> Source? in
  guard let name = package["name"] as? String, let manifest = package["manifest_path"] as? String
  else { return nil }
  let directory = URL(fileURLWithPath: manifest).deletingLastPathComponent()
  return Source(
    name: "rust:" + name + ":" + (package["version"] as? String ?? "unknown"), directory: directory,
    license: package["license"] as? String ?? "unrecorded",
    explicit: (package["license_file"] as? String).map {
      $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : directory.appendingPathComponent($0)
    })
}
sources.append(
  Source(
    name: "swift:MLXSwiftLM", directory: root.appendingPathComponent(".deps/MLXSwiftLM"),
    license: "inspect source notice", explicit: nil))
let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("App/Package.resolved"))) as? [String: Any]
let identities = Set((resolved?["pins"] as? [[String: Any]] ?? []).compactMap { $0["identity"] as? String })
let checkouts = root.appendingPathComponent("App/.build/checkouts")
if fm.fileExists(atPath: checkouts.path) {
  for folder in try fm.contentsOfDirectory(
    at: checkouts, includingPropertiesForKeys: [.isDirectoryKey])
  where identities.contains(folder.lastPathComponent.lowercased()) {
    guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
    sources.append(
      Source(
        name: "swift:" + folder.lastPathComponent, directory: folder,
        license: "inspect source notice", explicit: nil))
  }
}
try fm.createDirectory(at: destination, withIntermediateDirectories: true)
var inventory: [[String: Any]] = []
for source in sources.sorted(by: { $0.name < $1.name }) {
  var files = try fm.contentsOfDirectory(
    at: source.directory,
    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
  ).filter {
    let name = $0.lastPathComponent.lowercased()
    return name.hasPrefix("license") || name.hasPrefix("copying") || name.hasPrefix("notice")
  }
  if let explicit = source.explicit { files.append(explicit) }
  var retained: [String] = []
  for file in Set(files) {
    let v = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard v.isRegularFile == true, v.isSymbolicLink != true, (v.fileSize ?? Int.max) <= 4_194_304
    else { continue }
    let data = try Data(contentsOf: file)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let name = digest + "-" + file.lastPathComponent
    try data.write(to: destination.appendingPathComponent(name), options: .atomic)
    retained.append(name)
  }
  inventory.append([
    "package": source.name, "declared_license": source.license,
    "retained_notices": retained.sorted(), "requires_license_review": true,
  ])
}
let record: [String: Any] = [
  "schema": 1, "scope": "resolved source packages; may include non-linked or build dependencies",
  "distribution_approved": false, "packages": inventory,
]
let bytes = try JSONSerialization.data(
  withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
try bytes.write(to: URL(fileURLWithPath: args[4]), options: .atomic)
try bytes.write(to: destination.appendingPathComponent("inventory.json"), options: .atomic)
print("Retained source notices for review. This is not a distribution-license approval.")
