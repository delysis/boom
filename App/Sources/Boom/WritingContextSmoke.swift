import AppKit
import BoomCore
import Foundation

/// Explicit public fixtures, no user workspace, Keychain or visible windows.
@MainActor enum WritingContextSmoke {
  private struct Case: Codable {
    let name: String
    let document: DocumentSnapshot
    let caretUTF16: Int
    let examples: [String]
    let capacity: Int
    let exhaustive: Bool
  }
  private struct Suite: Codable { let cases: [Case] }
  static func run(arguments: [String]) async throws {
    func argument(_ name: String) throws -> String {
      guard arguments.filter({ $0 == name }).count == 1,
        let i = arguments.firstIndex(of: name), i + 1 < arguments.count,
        arguments[i + 1].hasPrefix("/") else { throw BoomError.invalid("Use absolute --fixture and --evidence paths.") }
      return arguments[i + 1]
    }
    let evidence = URL(fileURLWithPath: try argument("--evidence"))
    let fixture = URL(fileURLWithPath: try argument("--fixture"))
    guard !FileManager.default.fileExists(atPath: evidence.path), let pack = ModelPacks.cached(.writing) else {
      throw BoomError.invalid("Use a fresh evidence directory and the cached writing model.")
    }
    let bytes = try AttachmentProcessor.readGranted(fixture)
    guard bytes.count <= 4_194_304 else { throw BoomError.budget("Context fixtures exceed 4 MiB.") }
    let suite = try JSONDecoder().decode(Suite.self, from: bytes)
    guard !suite.cases.isEmpty, suite.cases.count <= 64 else { throw BoomError.invalid("Use one to 64 context cases.") }
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
    try bytes.write(to: evidence.appendingPathComponent("fixture.json"))
    var receipt: [String: Any] = ["status": "running", "source_inventory_sha256": Bundle.main.infoDictionary?["BoomSourceSHA256"] ?? "unavailable",
      "fixture_sha256": Digest.sha256(bytes), "hardware_bytes": ProcessInfo.processInfo.physicalMemory, "cases": []]
    func persist() throws {
      try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        .write(to: evidence.appendingPathComponent("receipt.json"), options: .atomic)
    }
    try persist()
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + .seconds(300))
    watchdog.setEventHandler { fputs("Context diagnostic exceeded its deadline; evidence retained.\n", stderr); exit(2) }
    watchdog.resume(); defer { watchdog.cancel() }
    do {
      let admission = try await detachedWork { try ModelPacks.admission(pack, purpose: .writing) }
      let runner = try await MLXGemmaRunner.load(admission: admission)
      receipt["model"] = runner.identity; try persist()
      var rows: [[String: Any]] = []
      for (index, fixture) in suite.cases.enumerated() {
        let clock = ContinuousClock(), started = clock.now
        var ticks = 0, maxTickGap = 0.0, lastTick = clock.now
        let ticker = Task { @MainActor in
          while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
            let now = clock.now
            maxTickGap = max(maxTickGap, lastTick.duration(to: now).timeInterval); lastTick = now; ticks += 1
          }
        }
        let result: (WritingPrompt, Int)
        do {
          result = try await runner.writingContext(document: fixture.document, caret: fixture.caretUTF16,
            examples: fixture.examples, capacity: fixture.capacity, flag: CancellationFlag())
        } catch { ticker.cancel(); await ticker.value; throw error }
        ticker.cancel(); await ticker.value
        let elapsed = started.duration(to: clock.now).timeInterval
        var row: [String: Any] = ["name": fixture.name, "capacity": fixture.capacity,
          "seconds": elapsed, "tested_candidates": result.1, "prompt": try ProductCore.object(result.0),
          "prompt_tokens": await runner.tokenCount(result.0.prompt), "main_loop_ticks": ticks, "max_tick_gap_seconds": maxTickGap]
        rows.append(row); receipt["cases"] = rows; try persist()
        if fixture.exhaustive {
          let full = try ProductCore.writingPrompt(fixture.document, caret: fixture.caretUTF16, examples: fixture.examples, retaining: Int.max)
          guard full.totalCharacters <= 1024 else { throw BoomError.invalid("Exhaustive fixtures are limited to 1024 graphemes.") }
          var counts: [Int] = [], largest: WritingPrompt?
          for keep in 1...full.totalCharacters {
            let candidate = try ProductCore.writingPrompt(fixture.document, caret: fixture.caretUTF16, examples: fixture.examples, retaining: keep)
            let count = await runner.tokenCount(candidate.prompt); counts.append(count)
            if count <= fixture.capacity { largest = candidate }
          }
          row["all_suffix_token_counts"] = counts
          row["all_larger_suffixes_fail"] = largest?.prompt.utf8.elementsEqual(result.0.prompt.utf8) ?? false
          rows[index] = row; receipt["cases"] = rows; try persist()
          guard let largest, largest.prompt.utf8.elementsEqual(result.0.prompt.utf8), largest.omittedCharacters == result.0.omittedCharacters else {
            throw BoomError.invalid("The selected context was not the largest fitting suffix; all counts retained.")
          }
        }
        guard await runner.tokenCount(result.0.prompt) <= fixture.capacity else { throw BoomError.budget("Selected context exceeded its capacity.") }
      }
      let cancelled = CancellationFlag(); cancelled.cancel()
      let first = suite.cases[0]
      do {
        _ = try await runner.writingContext(document: first.document, caret: first.caretUTF16, examples: first.examples,
          capacity: first.capacity, flag: cancelled)
        throw BoomError.invalid("A cancelled context request was admitted.")
      } catch is CancellationError { receipt["pre_cancel_rejected"] = true }
      if let long = suite.cases.first(where: { $0.document.text.utf8.count > 32_768 }) {
        let flag = CancellationFlag(), clock = ContinuousClock(), started = clock.now
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + .milliseconds(50)); timer.setEventHandler { flag.cancel() }; timer.resume()
        defer { timer.cancel() }
        do {
          _ = try await runner.writingContext(document: long.document, caret: long.caretUTF16, examples: long.examples,
            capacity: long.capacity, flag: flag)
          throw BoomError.invalid("The long context request finished before interruption was exercised.")
        } catch is CancellationError {
          receipt["interrupted_context_seconds"] = started.duration(to: clock.now).timeInterval
          receipt["interrupted_context_rejected"] = true
        }
        // A fresh operation must still work after the cancelled search releases
        // its snapshot; cancellation cannot poison the shared vocabulary.
        _ = try await runner.writingContext(document: first.document, caret: first.caretUTF16, examples: first.examples,
          capacity: first.capacity, flag: CancellationFlag())
        receipt["fresh_context_after_interruption"] = true
      }
      receipt["status"] = "passed"; try persist()
      print("Exact context diagnostic passed: \(evidence.path)")
    } catch { receipt["status"] = "failed"; receipt["failure"] = error.localizedDescription; try persist(); throw error }
  }
}
