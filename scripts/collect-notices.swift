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
  let workspaceMember: Bool
  let repository: String?
}
let workspaceMembers = Set(object?["workspace_members"] as? [String] ?? [])
let isProductWorkspace = (object?["workspace_root"] as? String).map {
  URL(fileURLWithPath: $0).standardizedFileURL == root.standardizedFileURL
} ?? false
func noticeName(_ name: String) -> Bool {
  let name = name.lowercased()
  return ["license", "licence", "copying", "notice", "authors", "copyright", "attributions"].contains { name.hasPrefix($0) }
}
/// Only top-level notices and one bounded LICENSES/LICENCES directory are eligible.
func noticeFiles(_ directory: URL) throws -> [URL] {
  let entries = try fm.contentsOfDirectory(at: directory,
    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
  var files: [URL] = []
  for entry in entries where noticeName(entry.lastPathComponent) {
    let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    if ["licenses", "licences"].contains(entry.lastPathComponent.lowercased()),
      values.isDirectory == true, values.isSymbolicLink != true {
      let children = try fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)
      guard children.count <= 128 else { throw NSError(domain: "NoticeDirectoryLimit", code: 1) }
      files.append(contentsOf: children)
    } else { files.append(entry) }
  }
  return files
}
struct SupplementalFile: Decodable {
  let path: String
  let upstream_path: String
  let git_blob: String
  let sha256: String
}
struct SupplementalPackage: Decodable {
  let package: String
  let repository: String
  let revision: String
  let files: [SupplementalFile]
}
struct SupplementalInventory: Decodable { let schema: Int; let packages: [SupplementalPackage] }
struct RuntimeOverlay: Decodable {
  struct File: Decodable { let path: String; let sha256: String }
  let directory: String
  let revision: String
  let patch: String
  let patchSHA256: String
  let files: [File]
  var provenance: [String: Any] {
    ["source_directory": directory, "upstream_revision": revision,
      "compiled_source": "tracked_overlay", "patch": patch, "patch_sha256": patchSHA256,
      "postimages": files.map { ["path": $0.path, "sha256": $0.sha256] }]
  }
}
let overlaysURL = root.appendingPathComponent("patches/mlx-runtime-overlays.json")
var runtimeOverlays: [RuntimeOverlay] = []
if fm.fileExists(atPath: overlaysURL.path) {
  let values = try overlaysURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
  guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 65_536 else {
    fatalError("Invalid tracked runtime overlay manifest")
  }
  runtimeOverlays = try JSONDecoder().decode([RuntimeOverlay].self, from: Data(contentsOf: overlaysURL))
  // This is the same verifier used before compilation. It admits no arbitrary
  // dirty checkout, and independently checks the nested C dependency.
  let verifier = Process()
  verifier.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  verifier.arguments = ["python3", root.appendingPathComponent("scripts/prepare-mlx-runtime.py").path, "--verify"]
  try verifier.run(); verifier.waitUntilExit()
  guard verifier.terminationStatus == 0 else { fatalError("Runtime overlay verification failed") }
}
func overlayFor(_ source: Source) -> RuntimeOverlay? {
  runtimeOverlays.first {
    root.appendingPathComponent($0.directory).standardizedFileURL == source.directory.standardizedFileURL
      && $0.revision == source.revision
  }
}
let supplementalURL = root.appendingPathComponent("licenses/supplemental.json")
var supplemental: [String: SupplementalPackage] = [:]
var supplementalInvalid = false
if fm.fileExists(atPath: supplementalURL.path) {
  do {
    let values = try supplementalURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 65_536 else {
      throw NSError(domain: "SupplementalNoticeManifest", code: 1)
    }
    let decoded = try JSONDecoder().decode(SupplementalInventory.self, from: Data(contentsOf: supplementalURL))
    guard decoded.schema == 1, decoded.packages.count <= 128 else { throw NSError(domain: "SupplementalNoticeManifest", code: 2) }
    for package in decoded.packages {
      guard supplemental[package.package] == nil, !package.files.isEmpty, package.files.count <= 128 else {
        throw NSError(domain: "SupplementalNoticeManifest", code: 3)
      }
      supplemental[package.package] = package
    }
  } catch { supplementalInvalid = true }
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
if supplementalInvalid {
  inventory.append(unresolved("supplemental:manifest", "invalid_supplemental_manifest"))
  sourceInventoryComplete = false
}
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
    }, revision: nil,
    workspaceMember: isProductWorkspace && package["source"] is NSNull
      && (package["id"] as? String).map { workspaceMembers.contains($0) } == true,
    repository: package["repository"] as? String))
}
sources.append(Source(name: "swift:MLXSwiftLM", directory: root.appendingPathComponent(".deps/MLXSwiftLM"),
  license: "inspect source notice", explicit: nil, revision: args[5], workspaceMember: false, repository: nil))
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
    license: "inspect source notice", explicit: nil, revision: revision, workspaceMember: false, repository: nil))
}
try fm.createDirectory(at: destination, withIntermediateDirectories: true)
if !runtimeOverlays.isEmpty {
  try fm.copyItem(at: overlaysURL, to: destination.appendingPathComponent("mlx-runtime-overlays.json"))
  for overlay in runtimeOverlays {
    try fm.copyItem(at: root.appendingPathComponent(overlay.patch),
      to: destination.appendingPathComponent(overlay.patchSHA256 + "-" + URL(fileURLWithPath: overlay.patch).lastPathComponent))
    // A nested dependency is a separate pinned source, not a cleanliness waiver
    // for its parent. Keep its own source notice and provenance in this inventory.
    if !sources.contains(where: { root.appendingPathComponent(overlay.directory).standardizedFileURL == $0.directory.standardizedFileURL }) {
      sources.append(Source(name: "swift:mlx-c", directory: root.appendingPathComponent(overlay.directory),
        license: "inspect source notice", explicit: nil, revision: overlay.revision,
        workspaceMember: false, repository: nil))
    }
  }
}
for source in sources.sorted(by: { $0.name < $1.name }) {
  if let revision = source.revision {
    let actual = git(source.directory, ["rev-parse", "HEAD"])
    guard actual == revision,
      overlayFor(source) != nil || git(source.directory, ["diff", "--quiet", "HEAD", "--"]) != nil else {
      inventory.append(unresolved(source.name, actual == revision ? "modified_checkout" : "revision_mismatch", revision: revision, actual: actual))
      sourceInventoryComplete = false
      continue
    }
  }
  guard var files = try? noticeFiles(source.directory) else {
    inventory.append(unresolved(source.name, "source_unavailable", revision: source.revision))
    sourceInventoryComplete = false
    continue
  }
  if source.workspaceMember {
    guard source.directory.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
      let inherited = try? noticeFiles(root) else {
      inventory.append(unresolved(source.name, "invalid_workspace_source"))
      sourceInventoryComplete = false
      continue
    }
    // Workspace members may inherit their product notices. Registry crates never do.
    files.append(contentsOf: inherited.filter {
      $0.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
        && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
    })
  }
  if let explicit = source.explicit { files.append(explicit) }
  var retained: [String] = [], rejected: [String] = []
  var hashes: [URL: SupplementalFile] = [:]
  if let extra = supplemental[source.name] {
    let vcsURL = source.directory.appendingPathComponent(".cargo_vcs_info.json")
    let vcs = (try? Data(contentsOf: vcsURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let actualRevision = (vcs?["git"] as? [String: Any])?["sha1"] as? String
    if extra.repository == source.repository, extra.revision == actualRevision,
      extra.revision.count == 40, extra.revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
      for file in extra.files {
        let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 3, components.first == "licenses",
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
          file.git_blob.count == 40, file.sha256.count == 64 else {
          rejected.append(file.path); continue
        }
        let url = root.appendingPathComponent(file.path)
        var parent = url.deletingLastPathComponent(), safe = true
        while parent.standardizedFileURL.path != root.standardizedFileURL.path {
          if (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != false { safe = false; break }
          parent.deleteLastPathComponent()
        }
        guard safe else { rejected.append(file.path); continue }
        hashes[url] = file; files.append(url)
      }
    } else { rejected.append("supplemental_source_mismatch") }
  }
  for file in Set(files).sorted(by: { $0.path < $1.path }) {
    if source.revision != nil, hashes[file] == nil,
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
    if let expected = hashes[file] {
      let blob = Insecure.SHA1.hash(data: Data("blob \(data.count)\0".utf8) + data).map { String(format: "%02x", $0) }.joined()
      guard digest == expected.sha256, blob == expected.git_blob else {
        rejected.append(expected.path); continue
      }
    }
    let name = digest + "-" + file.lastPathComponent
    try data.write(to: destination.appendingPathComponent(name), options: .atomic)
    retained.append(name)
  }
  var row: [String: Any] = ["package": source.name, "declared_license": source.license,
    "status": retained.isEmpty ? "notices_missing" : (rejected.isEmpty ? "retained" : "notices_incomplete"),
    "retained_notices": retained.sorted(), "rejected_notices": rejected.sorted(), "requires_license_review": true]
  if let revision = source.revision { row["expected_revision"] = revision; row["actual_revision"] = revision }
  if let overlay = overlayFor(source) { row["runtime_overlay"] = overlay.provenance }
  if let extra = supplemental[source.name] { row["supplemental_revision"] = extra.revision; row["supplemental_repository"] = extra.repository }
  inventory.append(row)
}
let record: [String: Any] = ["schema": 2,
  "scope": "expected resolved source packages; may include non-linked or build dependencies",
  "distribution_approved": false, "source_inventory_complete": sourceInventoryComplete,
  "model_pack_conversion_upstream_revision": args[5],
  "compiled_runtime_overlays": runtimeOverlays.map(\.provenance),
  "notices_complete": sourceInventoryComplete && inventory.allSatisfy { $0["status"] as? String == "retained" },
  "packages": inventory.sorted { ($0["package"] as? String ?? "") < ($1["package"] as? String ?? "") }]
let bytes = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
try bytes.write(to: URL(fileURLWithPath: args[4]), options: .atomic)
try bytes.write(to: destination.appendingPathComponent("inventory.json"), options: .atomic)
print("Retained source notices and unresolved outcomes for review. This is not a distribution-license approval.")
if record["notices_complete"] as? Bool != true { exit(1) }
