#!/usr/bin/env swift
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 6 else {
  fatalError("usage: collect-notices.swift PRODUCT_ROOT CARGO_METADATA OUTPUT_DIRECTORY INVENTORY_JSON MLX_REVISION")
}
let root = URL(fileURLWithPath: args[1])
let destination = URL(fileURLWithPath: args[3])
let fm = FileManager.default
let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as? [String: Any]
guard let packages = object?["packages"] as? [Any], !packages.isEmpty else {
  fatalError("Missing cargo package metadata")
}
struct Source {
  let name: String
  let directory: URL
  let license: String
  let explicit: URL?
  let revision: String?
}
func git(_ directory: URL, _ arguments: [String]) -> String? {
  let process = Process(), output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = ["-C", directory.path] + arguments
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  do { try process.run() } catch { return nil }
  let bytes = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { return nil }
  return String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}
func unresolved(_ name: String, _ status: String, revision: String? = nil, actual: String? = nil) -> [String: Any] {
  var row: [String: Any] = ["package": name, "status": status, "retained_notices": [String](), "requires_license_review": true]
  if let revision { row["expected_revision"] = revision }
  if let actual { row["actual_revision"] = actual }
  return row
}
var sources: [Source] = []
var inventory: [[String: Any]] = []
var sourceInventoryComplete = true
for (index, entry) in packages.enumerated() {
  guard let package = entry as? [String: Any],
    let name = package["name"] as? String, !name.isEmpty,
    let version = package["version"] as? String, !version.isEmpty,
    let manifest = package["manifest_path"] as? String, manifest.hasPrefix("/") else {
    inventory.append(unresolved("rust:metadata-entry-\(index)", "invalid_metadata"))
    sourceInventoryComplete = false
    continue
  }
  sources.append(Source(name: "rust:" + name + ":" + version,
    directory: URL(fileURLWithPath: manifest).deletingLastPathComponent(),
    license: package["license"] as? String ?? "unrecorded",
    explicit: (package["license_file"] as? String).map {
      $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : URL(fileURLWithPath: manifest).deletingLastPathComponent().appendingPathComponent($0)
    }, revision: nil))
}
sources.append(Source(name: "swift:MLXSwiftLM", directory: root.appendingPathComponent(".deps/MLXSwiftLM"),
  license: "inspect source notice", explicit: nil, revision: args[5]))
let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("App/Package.resolved"))) as? [String: Any]
guard let pins = resolved?["pins"] as? [Any], !pins.isEmpty else { fatalError("Missing Swift package pins") }
let checkouts = root.appendingPathComponent("App/.build/checkouts")
let folders = fm.fileExists(atPath: checkouts.path)
  ? try fm.contentsOfDirectory(at: checkouts, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) : []
var identities = Set<String>()
for (index, entry) in pins.enumerated() {
  guard let pin = entry as? [String: Any], let identity = pin["identity"] as? String,
    !identity.isEmpty, identity.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) }),
    let state = pin["state"] as? [String: Any], let revision = state["revision"] as? String,
    revision.count == 40, revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
    inventory.append(unresolved("swift:pin-entry-\(index)", "invalid_pin"))
    sourceInventoryComplete = false
    continue
  }
  guard identities.insert(identity).inserted else {
    inventory.append(unresolved("swift:" + identity, "duplicate_pin", revision: revision))
    sourceInventoryComplete = false
    continue
  }
  let matches = folders.filter { $0.lastPathComponent.lowercased() == identity }
  guard matches.count == 1, let directory = matches.first else {
    inventory.append(unresolved("swift:" + identity, matches.isEmpty ? "missing_checkout" : "duplicate_checkout", revision: revision))
    sourceInventoryComplete = false
    continue
  }
  let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
  guard values.isDirectory == true, values.isSymbolicLink != true else {
    inventory.append(unresolved("swift:" + identity, "invalid_checkout", revision: revision))
    sourceInventoryComplete = false
    continue
  }
  sources.append(Source(name: "swift:" + identity, directory: directory,
    license: "inspect source notice", explicit: nil, revision: revision))
}
try fm.createDirectory(at: destination, withIntermediateDirectories: true)
for source in sources.sorted(by: { $0.name < $1.name }) {
  if let revision = source.revision {
    let actual = git(source.directory, ["rev-parse", "HEAD"])
    guard actual == revision, git(source.directory, ["diff", "--quiet", "HEAD", "--"]) != nil else {
      inventory.append(unresolved(source.name, actual == revision ? "modified_checkout" : "revision_mismatch", revision: revision, actual: actual))
      sourceInventoryComplete = false
      continue
    }
  }
  guard let entries = try? fm.contentsOfDirectory(at: source.directory,
    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
    inventory.append(unresolved(source.name, "source_unavailable", revision: source.revision))
    sourceInventoryComplete = false
    continue
  }
  var files = entries.filter {
    let name = $0.lastPathComponent.lowercased()
    return name.hasPrefix("license") || name.hasPrefix("copying") || name.hasPrefix("notice")
  }
  if let explicit = source.explicit { files.append(explicit) }
  var retained: [String] = [], rejected: [String] = []
  for file in Set(files).sorted(by: { $0.path < $1.path }) {
    if source.revision != nil,
      git(source.directory, ["ls-files", "--error-unmatch", "--", file.path]) == nil {
      rejected.append(file.lastPathComponent)
      continue
    }
    guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
      values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4_194_304,
      let data = try? Data(contentsOf: file) else {
      rejected.append(file.lastPathComponent)
      continue
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let name = digest + "-" + file.lastPathComponent
    try data.write(to: destination.appendingPathComponent(name), options: .atomic)
    retained.append(name)
  }
  var row: [String: Any] = ["package": source.name, "declared_license": source.license,
    "status": retained.isEmpty ? "notices_missing" : (rejected.isEmpty ? "retained" : "notices_incomplete"),
    "retained_notices": retained.sorted(), "rejected_notices": rejected.sorted(), "requires_license_review": true]
  if let revision = source.revision { row["expected_revision"] = revision; row["actual_revision"] = revision }
  inventory.append(row)
}
let record: [String: Any] = ["schema": 2,
  "scope": "expected resolved source packages; may include non-linked or build dependencies",
  "distribution_approved": false, "source_inventory_complete": sourceInventoryComplete,
  "notices_complete": sourceInventoryComplete && inventory.allSatisfy { $0["status"] as? String == "retained" },
  "packages": inventory.sorted { ($0["package"] as? String ?? "") < ($1["package"] as? String ?? "") }]
let bytes = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
try bytes.write(to: URL(fileURLWithPath: args[4]), options: .atomic)
try bytes.write(to: destination.appendingPathComponent("inventory.json"), options: .atomic)
print("Retained source notices and unresolved outcomes for review. This is not a distribution-license approval.")
if !sourceInventoryComplete { exit(1) }
