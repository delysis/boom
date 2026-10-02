#!/usr/bin/env swift
import Foundation

// rustc, not a hand-maintained guess, supplies the static library's native links.
// Arguments are serialized as data; neither this script nor Package.swift evals them.
let args = CommandLine.arguments
guard args.count == 3 else { fatalError("usage: record-native-libs.swift RUSTC_LOG OUTPUT_JSON") }
let text = try String(contentsOfFile: args[1], encoding: .utf8)
let matches = text.components(separatedBy: .newlines).filter { $0.contains("native-static-libs:") }
guard let last = matches.last, let range = last.range(of: "native-static-libs:") else {
  fatalError("rustc did not emit native-static-libs; do not guess linker dependencies")
}
let flags = last[range.upperBound...].split(whereSeparator: { $0.isWhitespace }).map(String.init)
guard !flags.isEmpty, flags.count <= 128,
  flags.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_./,:=+@-]+$"#, options: .regularExpression) != nil }
  )
else {
  fatalError("Unrecognized native linker flag quoting. Inspect the rustc receipt.")
}
let output = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(
  at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try JSONSerialization.data(withJSONObject: flags, options: [.prettyPrinted]).write(
  to: output, options: .atomic)
print("Recorded \(flags.count) native linker arguments from rustc.")
