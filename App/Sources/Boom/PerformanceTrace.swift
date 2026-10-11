import Foundation
import os

/// Opt-in Instruments markers. Only fixed stage names and token counts leave
/// the process; manuscript text, paths, model input and identities never do.
/// Profiled runs are diagnostic and cannot supply acceptance timing.
enum PerformanceTrace {
  private static let enabled = ProcessInfo.processInfo.environment["BLOOM_PERFORMANCE_TRACE"] == "1"
  private static let log = OSLog(subsystem: "com.delysis.Bloom", category: .pointsOfInterest)

  static func begin(_ name: StaticString) -> OSSignpostID? {
    guard enabled, log.signpostsEnabled else { return nil }
    let id = OSSignpostID(log: log)
    os_signpost(.begin, log: log, name: name, signpostID: id)
    return id
  }
  static func end(_ name: StaticString, _ id: OSSignpostID?) {
    guard let id else { return }
    os_signpost(.end, log: log, name: name, signpostID: id)
  }
  static func event(_ name: StaticString) {
    guard enabled, log.signpostsEnabled else { return }
    os_signpost(.event, log: log, name: name)
  }
  static func prefill(processed: Int, total: Int) {
    guard enabled, log.signpostsEnabled else { return }
    os_signpost(.event, log: log, name: "Model.PrefillSubmission",
      "processed=%{public}lld total=%{public}lld", Int64(processed), Int64(total))
  }
}
