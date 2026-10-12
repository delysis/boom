import Foundation
import os
import Synchronization

/// Opt-in Instruments markers. Only fixed stage names and token counts leave
/// the process; manuscript text, paths, model input and identities never do.
/// Profiled runs are diagnostic and cannot supply acceptance timing.
enum PerformanceTrace {
  private static let enabled = ProcessInfo.processInfo.environment["BLOOM_PERFORMANCE_TRACE"] == "1"
  private static let log = OSLog(subsystem: "com.delysis.Bloom", category: .pointsOfInterest)
  #if BLOOM_DEVELOPER_STACK_DIAGNOSTICS
  struct Span {
    let signpost: OSSignpostID?
    let diagnostic: DeveloperStackDiagnostics.Token?
  }
  #else
  typealias Span = OSSignpostID
  #endif

  /// One main-actor publication per response. This observes state assignment,
  /// not compositor presentation, and never retains generated text.
  final class FirstDelivery: Sendable {
    private let publishedOnce = Mutex(false)
    func published() {
      let first = publishedOnce.withLock { published in
        guard !published else { return false }
        published = true
        return true
      }
      if first { PerformanceTrace.event("Request.FirstUIPublication") }
    }
  }
  static func firstDelivery() -> FirstDelivery? {
    #if BLOOM_DEVELOPER_STACK_DIAGNOSTICS
    guard enabled && log.signpostsEnabled || DeveloperStackDiagnostics.isReady else { return nil }
    #else
    guard enabled, log.signpostsEnabled else { return nil }
    #endif
    return FirstDelivery()
  }

  static func begin(_ name: StaticString) -> Span? {
    #if BLOOM_DEVELOPER_STACK_DIAGNOSTICS
    let diagnostic = DeveloperStackDiagnostics.begin(name)
    let signpost: OSSignpostID?
    if enabled && log.signpostsEnabled {
      let id = OSSignpostID(log: log)
      os_signpost(.begin, log: log, name: name, signpostID: id)
      signpost = id
    } else { signpost = nil }
    guard signpost != nil || diagnostic != nil else { return nil }
    return Span(signpost: signpost, diagnostic: diagnostic)
    #else
    guard enabled, log.signpostsEnabled else { return nil }
    let id = OSSignpostID(log: log)
    os_signpost(.begin, log: log, name: name, signpostID: id)
    return id
    #endif
  }
  /// A diagnostic event number correlates a slow edit with its nested stages.
  /// It identifies only the observation, never a document or source value.
  static func begin(_ name: StaticString, event: UInt64) -> Span? {
    #if BLOOM_DEVELOPER_STACK_DIAGNOSTICS
    let diagnostic = DeveloperStackDiagnostics.begin(name, event: event)
    let signpost: OSSignpostID?
    if enabled && log.signpostsEnabled {
      let id = OSSignpostID(log: log)
      os_signpost(.begin, log: log, name: name, signpostID: id,
        "event=%{public}llu", event)
      signpost = id
    } else { signpost = nil }
    guard signpost != nil || diagnostic != nil else { return nil }
    return Span(signpost: signpost, diagnostic: diagnostic)
    #else
    guard enabled, log.signpostsEnabled else { return nil }
    let id = OSSignpostID(log: log)
    os_signpost(.begin, log: log, name: name, signpostID: id,
      "event=%{public}llu", event)
    return id
    #endif
  }
  static func end(_ name: StaticString, _ span: Span?) {
    #if BLOOM_DEVELOPER_STACK_DIAGNOSTICS
    guard let span else { return }
    DeveloperStackDiagnostics.end(span.diagnostic)
    guard let id = span.signpost else { return }
    #else
    guard let id = span else { return }
    #endif
    os_signpost(.end, log: log, name: name, signpostID: id)
  }
  static func event(_ name: StaticString) {
    #if BLOOM_DEVELOPER_STACK_DIAGNOSTICS
    DeveloperStackDiagnostics.event(name)
    #endif
    guard enabled, log.signpostsEnabled else { return }
    os_signpost(.event, log: log, name: name)
  }
  static func prefill(processed: Int, total: Int) {
    #if BLOOM_DEVELOPER_STACK_DIAGNOSTICS
    DeveloperStackDiagnostics.prefill(processed: processed, total: total)
    #endif
    guard enabled, log.signpostsEnabled else { return }
    os_signpost(.event, log: log, name: "Model.PrefillSubmission",
      "processed=%{public}lld total=%{public}lld", Int64(processed), Int64(total))
  }
}
