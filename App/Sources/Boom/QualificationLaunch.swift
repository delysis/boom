import Foundation
import BoomCore

/// A qualification copy must remain scoped when LaunchServices or UI tooling
/// launches it without developer arguments. Ordinary signed bundles are unchanged.
enum QualificationLaunch {
  static let bundleID = "com.delysis.Bloom.VisibleQualification"
  static func scopedBundleID(_ scope: UUID) -> String {
    bundleID + "." + scope.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
  static func arguments(_ original: [String], bundleID: String?, fixture: [String: String]?, pid: Int32) throws -> [String] {
    guard bundleID == Self.bundleID || bundleID?.hasPrefix(Self.bundleID + ".") == true else {
      guard fixture == nil else { throw BoomError.invalid("A qualification fixture requires its isolated bundle identity.") }
      return original
    }
    guard let fixture, fixture.count == 3,
      let root = fixture["workspace"], root.hasPrefix("/"),
      let evidence = fixture["evidenceBase"], evidence.hasPrefix("/"),
      let scope = fixture["qualificationID"], UUID(uuidString: scope) != nil,
      !original.isEmpty else {
      throw BoomError.invalid("An isolated qualification bundle requires its public fixture binding before startup.")
    }
    guard bundleID == Self.bundleID || bundleID == scopedBundleID(UUID(uuidString: scope)!) else {
      throw BoomError.invalid("The qualification identity does not match its public fixture binding.")
    }
    return [original[0], "--native-check-workspace", root,
      "--native-check-qualification-id", scope,
      "--native-check-evidence", URL(fileURLWithPath: evidence).appendingPathComponent(String(pid)).path,
      "--native-check-no-models"]
  }
  static func current() throws -> [String] {
    try arguments(CommandLine.arguments, bundleID: Bundle.main.bundleIdentifier,
      fixture: Bundle.main.object(forInfoDictionaryKey: "BloomQualificationFixture") as? [String: String],
      pid: ProcessInfo.processInfo.processIdentifier)
  }
}
