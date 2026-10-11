import AppKit
import BoomCore
import CryptoKit
import SwiftUI
import XCTest
@testable import Boom

final class ManuscriptViewportTests: XCTestCase {
  /// A fixed-arrival CPU-only stress observation. No model requests are added
  /// to obtain samples, and no slow input is skipped or replaced by a new clock.
  @MainActor func testLongManuscriptTailDistribution() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["BLOOM_QUALIFICATION_EDITOR_FIXTURE"],
      let stratum = environment["BLOOM_EDITOR_TAIL_PATH"],
      let evidencePath = environment["BLOOM_EDITOR_TAIL_EVIDENCE"] else {
      throw XCTSkip("Enable a public editor tail stratum and a fresh evidence file explicitly.")
    }
    guard ["head", "middle", "tail"].contains(stratum) else {
      throw BoomError.invalid("Unknown editor tail stratum.")
    }
    let diagnosticLimit = environment["BLOOM_EDITOR_TAIL_DIAGNOSTIC_EVENTS"]
    let requestedEvents: Int
    if let diagnosticLimit {
      guard environment["BLOOM_PERFORMANCE_TRACE"] == "1",
        let count = Int(diagnosticLimit), (1000...2000).contains(count) else {
        throw BoomError.invalid("Editor attribution requires tracing and1000...2000 declared diagnostic events.")
      }
      requestedEvents = count
    } else { requestedEvents = 10_000 }
    let diagnostic = diagnosticLimit != nil
    let evidence = URL(fileURLWithPath: evidencePath)
    guard !FileManager.default.fileExists(atPath: evidence.path) else {
      throw BoomError.invalid("Editor tail evidence already exists.")
    }
    let bytes = try RegularFile(URL(fileURLWithPath: path), limit: 512 * 1024).data()
    let document = try JSONDecoder().decode(DocumentSnapshot.self, from: bytes)
    let original = Data(document.text.utf8)
    let text = document.text as NSString
    let location: Int
    switch stratum {
    case "head": location = 0
    case "middle": location = text.length == 0 ? 0 : text.rangeOfComposedCharacterSequence(at: text.length / 2).location
    default: location = text.length
    }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-editor-tail-" + UUID().uuidString)
    let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
    var state = WorkspaceState(); state.autocomplete = false; state.showChat = false
    state.documents = [.init(id: document.id, title: document.title)]; state.selectedDocument = document.id
    try await store.save(state, documents: [document])
    let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
    guard model.layout.isAuthor else {
      try await model.shutdown(); try FileManager.default.removeItem(at: root)
      throw XCTSkip("The Chat edition has no manuscript pane.")
    }
    let clock = ContinuousClock(), setupStarted = ContinuousClock().now
    let host = NSHostingView(rootView: WorkspaceView(model: model))
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 846))
    window.isReleasedWhenClosed = false; window.contentView = host
    var failure: Error?
    var runner: EditorTailRun?
    var producerStarted = false, producerJoined = true
    do {
      for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
      let editor = try XCTUnwrap(model.editor)
      guard window.makeFirstResponder(editor) else { throw BoomError.invalid("Editor focus was unavailable.") }
      model.isBusy = true
      editor.setSelectedRange(NSRange(location: location, length: 0)); editor.scrollRangeToVisible(editor.selectedRange())
      host.layoutSubtreeIfNeeded()
      let run = try EditorTailRun(editor: editor, host: host, window: window,
        model: model, location: location, originalLength: text.length)
      runner = run
      let started = clock.now
      // A non-main producer stamps actual enqueue time. Waiting for each edit
      // bounds the queue to one event while retaining any arrival backlog.
      producerStarted = true; producerJoined = false
      let producer = Task.detached {
        for index in 0..<requestedEvents {
          try Task.checkCancellation()
          guard clock.now < started.advanced(by: .seconds(900)) else {
            throw BoomError.unavailable("Editor tail observation exceeded its 900-second bound.")
          }
          let deadline = started.advanced(by: .milliseconds((index + 1) * 20))
          try await Task.sleep(until: deadline, clock: clock)
          let enqueued = clock.now
          try await run.measure(event: UInt64(index), origin: started, deadline: deadline, enqueued: enqueued)
        }
      }
      let producerResult = await withTaskCancellationHandler(
        operation: { await producer.result }, onCancel: { producer.cancel() })
      producerJoined = true
      try producerResult.get()
      run.detachObservers()
      // Full source verification is outside the measured loop. Per-event
      // guards inspect only native length, one inserted character and focus.
      guard Data(editor.string.utf8) == original,
        Data(model.selectedDocument?.text.utf8 ?? "".utf8) == original else {
        throw BoomError.invalid("Editor tail observation changed the public source.")
      }
    } catch { failure = error }
    runner?.detachObservers()
    let samples = runner?.samples ?? []
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let encodedSamples = try encoder.encode(samples)
    let rawSamples = try JSONSerialization.jsonObject(with: encodedSamples)
    var statistics: [String: Any] = [:]
    let deferredWaits: [TimeInterval] = samples.map { sample in
      sample.deferred.map { observation in observation.started - observation.scheduled }.max() ?? 0
    }
    let deferredWork: [TimeInterval] = samples.map { sample in
      sample.deferred.reduce(0.0) { total, observation in total + observation.ended - observation.started }
    }
    let measuredValues: [(String, [TimeInterval])] = [
      ("arrival_lateness", samples.map(\.arrivalLateness)),
      ("main_actor_wait", samples.map(\.mainActorWait)),
      ("insertion", samples.map(\.insertion)), ("deletion", samples.map(\.deletion)),
      ("immediate_layout", samples.map(\.immediateLayout)),
      ("deferred_barrier", samples.map(\.deferredBarrier)),
      ("native_deferred_wait", deferredWaits),
      ("native_deferred_work", deferredWork),
      ("settled_layout", samples.map(\.settledLayout)),
      ("raster_draw", samples.map(\.rasterDraw)), ("service", samples.map(\.service)),
      ("scheduled_to_draw_return", samples.map(\.scheduledToDrawReturn))
    ]
    for (name, values) in measuredValues {
      let ordered = values.sorted()
      guard !ordered.isEmpty else { continue }
      var ranks: [String: Any] = [:]
      for (label, probability) in [("p50", 0.5), ("p99", 0.99), ("p99_9", 0.999)] {
        let rank = Int(ceil(probability * Double(ordered.count)))
        ranks[label] = ["nearest_rank": rank, "seconds": ordered[rank - 1], "events_above_rank": ordered.count - rank]
      }
      ranks["maximum_seconds"] = ordered.last!
      ranks["slowest_event_ids"] = values.indices.sorted { values[$0] > values[$1] }.prefix(20).map { samples[$0].event }
      statistics[name] = ranks
    }
    let slowest = samples.sorted { $0.scheduledToDrawReturn > $1.scheduledToDrawReturn }.prefix(100).map(\.event)
    let observation: [String: Any] = [
      "fixture_sha256": Digest.sha256(bytes), "stratum": stratum, "utf16_length": text.length,
      "requested_events": requestedEvents, "completed_events": samples.count, "cadence_seconds": 0.020,
      "validated_events": runner?.validatedEvents ?? 0,
      "producer_started": producerStarted, "producer_joined": producerJoined,
      "partial_events": try JSONSerialization.jsonObject(with: encoder.encode(runner?.partialEvents ?? [])),
      "status": failure == nil && samples.count == requestedEvents ? (diagnostic ? "diagnostic_complete" : "complete") : "incomplete",
      "diagnostic": diagnostic,
      "p999_population_qualified": false,
      "full_distribution_observed": !diagnostic && samples.count == 10_000,
      "failure": failure.map { $0.localizedDescription as Any } ?? NSNull(),
      "failure_event": runner?.currentEvent.map { NSNumber(value: $0) as Any } ?? NSNull(),
      "setup_and_observation_seconds": setupStarted.duration(to: clock.now).timeInterval,
      "tracing_enabled": environment["BLOOM_PERFORMANCE_TRACE"] == "1",
      "statistics_seconds": statistics, "slowest_event_ids": slowest, "samples": rawSamples,
      "scope": "Fixed 20ms nominal deadlines, one outstanding event with producer backpressure and retained deadline lateness; offscreen production WorkspaceView; insert/delete, actual deferred invalidation, settled layout and cached native viewport raster drawing. No models, ghost, physical event dispatch, IME or compositor presentation. First event and all tails retained; no warmup edits or per-event whole-source comparisons."
    ]
    var settledObservation = observation
    window.close()
    var shutdownCompleted = false, rootRemoved = false
    do { try await model.shutdown(); shutdownCompleted = true } catch { if failure == nil { failure = error } }
    do { try FileManager.default.removeItem(at: root); rootRemoved = true } catch { if failure == nil { failure = error } }
    settledObservation["cleanup_joined"] = producerJoined && shutdownCompleted
    settledObservation["cleanup_succeeded"] = shutdownCompleted && rootRemoved
    settledObservation["failure"] = failure.map { $0.localizedDescription as Any } ?? NSNull()
    if failure != nil { settledObservation["status"] = "incomplete" }
    try JSONSerialization.data(withJSONObject: settledObservation, options: [.sortedKeys]).write(to: evidence, options: .withoutOverwriting)
    print("EDITOR_TAIL_OBSERVATION " + String(decoding: try JSONSerialization.data(withJSONObject: [
      "stratum": stratum, "events": samples.count, "statistics_seconds": statistics,
      "status": settledObservation["status"]!, "evidence": evidence.path
    ], options: [.sortedKeys]), as: UTF8.self))
    if let failure { throw failure }
    XCTAssertEqual(samples.count, requestedEvents)
    XCTAssertEqual(runner?.validatedEvents, requestedEvents)
    XCTAssertTrue(producerJoined)
    XCTAssertTrue(samples.allSatisfy { !$0.deferred.isEmpty && !$0.draws.isEmpty }, "Each event needs observed native invalidation and drawing.")
  }
  /// Explicit public fixture only. These component observations are separate
  /// from packaged model-load, physical typing and release performance gates.
  @MainActor func testCapturedLongManuscriptScrollEditAndResize() async throws {
    guard let path = ProcessInfo.processInfo.environment["BLOOM_QUALIFICATION_EDITOR_FIXTURE"] else {
      throw XCTSkip("Enable the captured public manuscript comparison explicitly.")
    }
    let url = URL(fileURLWithPath: path)
    let bytes = try RegularFile(url, limit: 512 * 1024).data()
    let document = try JSONDecoder().decode(DocumentSnapshot.self, from: bytes)
    let fixtureHash = Digest.sha256(bytes)
    _ = NSApplication.shared
    for repetition in 0..<3 {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bloom-viewport-" + UUID().uuidString)
      let store = try WorkspaceStore(rootOverride: root, testKey: SymmetricKey(size: .bits256))
      var state = WorkspaceState(); state.autocomplete = false; state.showChat = false
      state.documents = [.init(id: document.id, title: document.title)]
      state.selectedDocument = document.id
      try await store.save(state, documents: [document])
      let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
      guard model.layout.isAuthor else { throw XCTSkip("The Chat edition has no manuscript pane.") }
      let host = NSHostingView(rootView: WorkspaceView(model: model))
      let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10_000, y: -10_000, width: 1190, height: 846))
      window.isReleasedWhenClosed = false; window.contentView = host
      for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
      let editor = try XCTUnwrap(model.editor)
      XCTAssertTrue(window.makeFirstResponder(editor)); model.isBusy = true
      let clock = ContinuousClock()
      var samples: [[String: Double]] = []
      for _ in 0..<12 {
        try await Task.sleep(for: .milliseconds(100))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let start = clock.now
        editor.insertText("x", replacementRange: editor.selectedRange())
        let inserted = clock.now
        editor.insertText("", replacementRange: NSRange(location: 0, length: 1))
        let deleted = clock.now
        host.layoutSubtreeIfNeeded()
        let end = clock.now
        samples.append(["insertion": start.duration(to: inserted).timeInterval,
          "deletion": inserted.duration(to: deleted).timeInterval,
          "layout": deleted.duration(to: end).timeInterval,
          "total": start.duration(to: end).timeInterval])
        XCTAssertEqual(editor.string, document.text)
        XCTAssertEqual(model.selectedDocument?.text, document.text)
        XCTAssertTrue(window.firstResponder === editor)
      }
      for width in [1190.0, 680.0, 980.0, 1190.0] {
        window.setContentSize(NSSize(width: width, height: 846))
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25))
        let layout = try XCTUnwrap(editor.layoutManager), container = try XCTUnwrap(editor.textContainer)
        let tail = NSRange(location: max(0, document.text.utf16.count - 20), length: min(20, document.text.utf16.count))
        layout.ensureLayout(forCharacterRange: tail)
        let glyphs = layout.glyphRange(forCharacterRange: tail, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
          .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        editor.scrollRangeToVisible(tail); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor.visibleRect.intersects(rect), "The final authored text must remain reachable at width \(width).")
        XCTAssertLessThanOrEqual(container.size.width + editor.textContainerInset.width * 2,
          max(editor.bounds.width, WorkspaceGeometry.proseMaximumWidth))
        XCTAssertEqual(editor.string, document.text)
      }
      let observation: [String: Any] = ["fixture_sha256": fixtureHash, "repetition": repetition,
        "utf16_length": document.text.utf16.count, "samples": samples,
        "scope": "Public production-view insertion, deletion and layout without models; component observations only"]
      print("EDITOR_VIEWPORT_OBSERVATION " + String(decoding: try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]), as: UTF8.self))
      window.close(); try await model.shutdown()
      try FileManager.default.removeItem(at: root)
    }
  }
}

private struct EditorTailStage: Codable, Sendable {
  let scheduled: Double
  let started: Double
  let ended: Double
}

private struct EditorTailSample: Codable, Sendable {
  let event: UInt64
  let scheduled: Double
  let enqueued: Double
  let entered: Double
  let arrivalLateness: Double
  let mainActorWait: Double
  let insertion: Double
  let deletion: Double
  let immediateLayout: Double
  let deferredBarrier: Double
  let settledLayout: Double
  let rasterDraw: Double
  let service: Double
  let scheduledToDrawReturn: Double
  let deferred: [EditorTailStage]
  let draws: [EditorTailStage]
}

private struct EditorTailPartial: Codable, Sendable {
  let event: UInt64
  let stage: String
  let scheduled: Double
  let enqueued: Double
  let entered: Double
  let failed: Double
  let stageEnds: [String: Double]
  let deferred: [EditorTailStage]
  let draws: [EditorTailStage]
  let error: String
}

@MainActor private final class EditorTailRun {
  let editor: MarkdownTextView
  let host: NSHostingView<WorkspaceView>
  let window: NSWindow
  let model: WorkspaceModel
  let location: Int
  let originalLength: Int
  let bitmap: NSBitmapImageRep
  private var cycleOrigin = ContinuousClock().now
  private var deferred: [EditorTailStage] = []
  private var draws: [EditorTailStage] = []
  private(set) var samples: [EditorTailSample] = []
  private(set) var currentEvent: UInt64?
  private(set) var validatedEvents = 0
  private(set) var partialEvents: [EditorTailPartial] = []

  init(editor: MarkdownTextView, host: NSHostingView<WorkspaceView>, window: NSWindow,
    model: WorkspaceModel, location: Int, originalLength: Int) throws {
    self.editor = editor; self.host = host; self.window = window; self.model = model
    self.location = location; self.originalLength = originalLength
    guard let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect) else {
      throw BoomError.unavailable("Native viewport raster backing was unavailable.")
    }
    self.bitmap = bitmap
    samples.reserveCapacity(10_000); deferred.reserveCapacity(2); draws.reserveCapacity(2)
    editor.deferredLayoutObservation = { [weak self] scheduled, started, ended in
      guard let self else { return }
      self.deferred.append(.init(scheduled: self.cycleOrigin.duration(to: scheduled).timeInterval,
        started: self.cycleOrigin.duration(to: started).timeInterval, ended: self.cycleOrigin.duration(to: ended).timeInterval))
    }
    editor.drawObservation = { [weak self] started, ended in
      guard let self else { return }
      let start = self.cycleOrigin.duration(to: started).timeInterval
      self.draws.append(.init(scheduled: start, started: start, ended: self.cycleOrigin.duration(to: ended).timeInterval))
    }
  }
  func detachObservers() { editor.deferredLayoutObservation = nil; editor.drawObservation = nil }
  func measure(event: UInt64, origin: ContinuousClock.Instant,
    deadline: ContinuousClock.Instant, enqueued: ContinuousClock.Instant) async throws {
    let clock = ContinuousClock(), entered = ContinuousClock().now
    currentEvent = event; cycleOrigin = entered
    deferred.removeAll(keepingCapacity: true); draws.removeAll(keepingCapacity: true)
    let trace = PerformanceTrace.begin("Editor.TailCycle", event: event)
    defer { PerformanceTrace.end("Editor.TailCycle", trace) }
    var stage = "precondition"
    var ends: (selection: Double?, inserted: Double?, deleteStarted: Double?, deleted: Double?,
      immediate: Double?, drained: Double?, laidOut: Double?, drawn: Double?) =
      (nil, nil, nil, nil, nil, nil, nil, nil)
    do {
      guard window.firstResponder === editor, !editor.hasMarkedText(),
        editor.textStorage?.length == originalLength else {
        throw BoomError.invalid("The editor tail precondition changed.")
      }
      stage = "selection"
      editor.setSelectedRange(NSRange(location: location, length: 0))
      let start = clock.now
      ends.selection = entered.duration(to: start).timeInterval
      stage = "insertion"
      editor.insertText("x", replacementRange: editor.selectedRange())
      let inserted = clock.now
      ends.inserted = entered.duration(to: inserted).timeInterval
      stage = "insertion_validation"
      guard let storage = editor.textStorage, storage.length == originalLength + 1,
        storage.mutableString.character(at: location) == 120 else {
        throw BoomError.invalid("The native insertion did not match its bounded observation.")
      }
      let deleteStarted = clock.now
      ends.deleteStarted = entered.duration(to: deleteStarted).timeInterval
      stage = "deletion"
      editor.insertText("", replacementRange: NSRange(location: location, length: 1))
      let deleted = clock.now
      ends.deleted = entered.duration(to: deleted).timeInterval
      stage = "immediate_layout"
      host.layoutSubtreeIfNeeded()
      let immediate = clock.now
      ends.immediate = entered.duration(to: immediate).timeInterval
      stage = "deferred_barrier"
      // The production view queues invalidation during its native transaction.
      // Drain that actual next-turn work before measuring settled layout/drawing.
      await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
      let drained = clock.now
      ends.drained = entered.duration(to: drained).timeInterval
      stage = "settled_layout"
      host.layoutSubtreeIfNeeded()
      let laidOut = clock.now
      ends.laidOut = entered.duration(to: laidOut).timeInterval
      stage = "raster_draw"
      editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
      let drawn = clock.now
      ends.drawn = entered.duration(to: drawn).timeInterval
      stage = "final_validation"
      samples.append(.init(event: event, scheduled: origin.duration(to: deadline).timeInterval,
        enqueued: origin.duration(to: enqueued).timeInterval, entered: origin.duration(to: entered).timeInterval,
        arrivalLateness: max(0, deadline.duration(to: enqueued).timeInterval),
        mainActorWait: enqueued.duration(to: entered).timeInterval,
        insertion: start.duration(to: inserted).timeInterval, deletion: deleteStarted.duration(to: deleted).timeInterval,
        immediateLayout: deleted.duration(to: immediate).timeInterval, deferredBarrier: immediate.duration(to: drained).timeInterval,
        settledLayout: drained.duration(to: laidOut).timeInterval, rasterDraw: laidOut.duration(to: drawn).timeInterval,
        service: entered.duration(to: drawn).timeInterval, scheduledToDrawReturn: deadline.duration(to: drawn).timeInterval,
        deferred: deferred, draws: draws))
      guard storage.length == originalLength, window.firstResponder === editor,
        model.selectedDocument?.id == editor.documentID, !deferred.isEmpty, !draws.isEmpty else {
        throw BoomError.invalid("The native source, focus, deferred layout or drawing observation was incomplete.")
      }
      validatedEvents += 1
      currentEvent = nil
    } catch {
      var stageEnds: [String: Double] = [:]
      for (name, value) in [("selection_start", ends.selection), ("insertion_end", ends.inserted),
        ("deletion_start", ends.deleteStarted), ("deletion_end", ends.deleted),
        ("immediate_layout_end", ends.immediate), ("deferred_barrier_end", ends.drained),
        ("settled_layout_end", ends.laidOut), ("raster_draw_end", ends.drawn)] {
        if let value { stageEnds[name] = value }
      }
      partialEvents.append(.init(event: event, stage: stage,
        scheduled: origin.duration(to: deadline).timeInterval,
        enqueued: origin.duration(to: enqueued).timeInterval,
        entered: origin.duration(to: entered).timeInterval,
        failed: origin.duration(to: clock.now).timeInterval, stageEnds: stageEnds,
        deferred: deferred, draws: draws, error: String(describing: error)))
      throw error
    }
  }
}
