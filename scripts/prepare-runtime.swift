#!/usr/bin/env swift
import CryptoKit
import Foundation

// Exact-source transformation; no fuzzy patching and no rewriting user changes.
let args = CommandLine.arguments
guard args.count == 3 else {
  fatalError("usage: prepare-runtime.swift COREML_CHECKOUT PRODUCT_ROOT")
}
let checkout = URL(fileURLWithPath: args[1])
let product = URL(fileURLWithPath: args[2])
let revision = "18a9b5fd3d7e1f1f5d182533c94d311a7e649f7c"
struct Failure: Error, CustomStringConvertible { let description: String }
func git(_ args: [String], input: Data? = nil) throws -> Data {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["git", "-C", checkout.path] + args
  let output = Pipe()
  let errors = Pipe()
  process.standardOutput = output
  process.standardError = errors
  if let input {
    let pipe = Pipe()
    process.standardInput = pipe
    try process.run()
    pipe.fileHandleForWriting.write(input)
    try pipe.fileHandleForWriting.close()
  } else {
    try process.run()
  }
  let result = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw Failure(
      description: String(
        decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
  }
  return result
}
do {
  let head = String(decoding: try git(["rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(
    in: .whitespacesAndNewlines)
  guard head == revision else { throw Failure(description: "Wrong CoreML-LLM revision: \(head)") }
  let files = [
    (
      "Sources/CoreMLLLM/CoreMLLLM.swift", "CoreMLLLM+Boom.swift.inc",
      "90cfb5dcea8e8bc79cc8f181b7d12724de77daee"
    ),
    (
      "Sources/CoreMLLLM/ChunkedEngine.swift", "ChunkedEngine+Boom.swift.inc",
      "f26d7a5a9f045ffab08404a21c065bf32b06f1af"
    ),
  ]
  var sourceIdentity = Data(revision.utf8)
  for (path, addition, expectedBlob) in files {
    let original = try git(["show", revision + ":" + path])
    let blob = String(
      decoding: try git(["hash-object", "--stdin"], input: original), as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard blob == expectedBlob else {
      throw Failure(description: "Pristine source blob differs: \(path)")
    }
    let append = try Data(
      contentsOf: product.appendingPathComponent("RuntimeAdditions/" + addition))
    var base = String(decoding: original, as: UTF8.self)
    if path.hasSuffix("ChunkedEngine.swift") {
      // Reviewed, exact replacements at the two local model-load sites.
      for (from, to) in [
        (
          "let m = try MLModel(contentsOf: url, configuration: cfg)",
          "let m = try ChunkedEngine.boomLoadCompiledModel(url, configuration: cfg)"
        ),
        (
          "let m = try MLModel(contentsOf: url, configuration: prefillConfigCopy)",
          "let m = try ChunkedEngine.boomLoadCompiledModel(url, configuration: prefillConfigCopy)"
        ),
      ] {
        guard base.components(separatedBy: from).count == 2 else {
          throw Failure(description: "Pinned local compile site is not unique: \(from)")
        }
        base = base.replacingOccurrences(of: from, with: to)
      }
    }
    var desired = Data(base.utf8)
    desired.append(append)
    sourceIdentity.append(desired)
    let destination = checkout.appendingPathComponent(path)
    let current = try Data(contentsOf: destination)
    guard current == original || current == desired else {
      throw Failure(description: "Refusing to overwrite local dependency changes: \(path)")
    }
    if current != desired { try desired.write(to: destination, options: .atomic) }
  }
  // Reject every environment-tuned inference route found in these exact sources,
  // including names outside LLM_ (GPU_PREFILL, LAYERSKIP_PROBE, etc.).
  let pattern = #"(?:environment\[|getenv\()\s*\"([A-Z][A-Z0-9_]*)\""#
  let regex = try NSRegularExpression(pattern: pattern)
  var keys = Set<String>()
  for name in [
    "CoreMLLLM.swift", "ChunkedEngine.swift", "EmbeddingLookup.swift", "ImageProcessor.swift",
    "AudioProcessor.swift",
  ] {
    let path = "Sources/CoreMLLLM/" + name
    let text = String(decoding: try git(["show", revision + ":" + path]), as: UTF8.self)
    let ns = text as NSString
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      keys.insert(ns.substring(with: match.range(at: 1)))
    }
  }
  keys.formUnion(["GPU_PREFILL", "LAYERSKIP_PROBE", "COMPUTE_PLAN_AUDIT"])
  let entries = keys.sorted().map { "\"" + $0 + "\"" }.joined(separator: ", ")
  let fingerprint = SHA256.hash(data: sourceIdentity).map { String(format: "%02x", $0) }.joined()
  let generated =
    "// Generated from exact pinned sources; do not edit.\nimport Foundation\npublic enum BoomBuildContract { public static let forbiddenEnvironment: Set<String> = [\(entries)]; public static let sourceFingerprint = \"\(fingerprint)\" }\n"
  let generatedURL = checkout.appendingPathComponent("Sources/CoreMLLLM/BoomBuildContract.swift")
  if FileManager.default.fileExists(atPath: generatedURL.path) {
    guard try String(contentsOf: generatedURL, encoding: .utf8) == generated else {
      throw Failure(description: "Refusing to overwrite a modified generated environment contract.")
    }
  } else {
    try Data(generated.utf8).write(to: generatedURL, options: .atomic)
  }
  print(
    "Prepared pinned CoreML source additions; \(keys.count) experimental environment controls are refused."
  )
} catch {
  fputs("\(error)\n", stderr)
  exit(1)
}
