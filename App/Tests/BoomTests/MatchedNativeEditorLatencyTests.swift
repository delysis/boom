import AppKit
import BoomCore
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import Boom

#if BLOOM_PAGED_SQL_PUBLIC_CONTROL
// Source-only current managed-native comparison port. Author uses its actual
// workspace editor; pager uses canonical opening, real input/Foundation owners
// and the actual production viewport with explicit bounded fixture typography.
private func matchedNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
private func matchedElapsed(_ start: UInt64) -> UInt64 { matchedNow() - start }

// The workspace contains only deterministic public fixtures. Retained failed
// scratch must remain decryptable without user Keychain access.
private func matchedPublicFixtureKey() -> SymmetricKey {
  SymmetricKey(data: Data(repeating: 0xa7, count: 32))
}
private struct MatchedRefusal: Error, LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}
private func matchedRequire(_ value: Bool, _ message: String) throws {
  guard value else { throw MatchedRefusal(message: message) }
}

private struct MatchedGeometry: Codable, Sendable, Equatable {
  let viewportWidth: Double
  let viewportHeight: Double
  let containerWidth: Double
  let lineFragmentPadding: Double
  let insetX: Double
  let insetY: Double
  let fontName: String
  let fontSize: Double
  let lineSpacing: Double
  let drawsBackground: Bool
  func validate() throws {
    let values = [viewportWidth, viewportHeight, containerWidth, lineFragmentPadding, insetX, insetY, fontSize, lineSpacing]
    try matchedRequire(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 4096 }, "Invalid matched geometry.")
    try matchedRequire(viewportWidth >= 200 && viewportHeight >= 100 && containerWidth >= 100
      && viewportWidth <= 1280 && viewportHeight <= 900 && viewportWidth * viewportHeight <= 1000000
      && fontSize >= 8 && fontSize <= 40 && fontName.utf8.count <= 128, "Unbounded matched native viewport.")
  }
}
private struct MatchedRecipe: Codable, Sendable {
  let schema: Int
  let lane: String
  let sourceBytes: UInt64
  let repetitions: Int
  let sourceProfile: String
  let geometry: MatchedGeometry?
  let pairID: UUID
  func validate() throws {
    try matchedRequire(schema == 1 && ["author", "paged126"].contains(lane) && repetitions == 8,
      "This driver admits only its fixed first comparison recipe.")
    try matchedRequire([UInt64(4096), 72196, 1048576, 1073741824].contains(sourceBytes)
      && (sourceBytes <= 1048576 || lane == "paged126"), "Source extent/lane is outside the public comparison.")
    try matchedRequire(sourceBytes == 1073741824 ? sourceProfile == "qualifiedGiB"
      : ["plainUnicode", "markdownBoundary"].contains(sourceProfile), "Unknown public source profile.")
    if lane == "paged126" { try matchedRequire(geometry != nil, "Paged geometry must come from the paired actual Author receipt.") }
    try geometry?.validate()
  }
}

/// Shared small sources contain NFC, NFD, supplementary and joined emoji.
/// 1 GiB uses the separately reviewed ASCII period from PagedGiBOracle.
private struct MatchedOracle: Sendable {
  let sourceBytes: UInt64
  let row: Data
  let rowText: String
  let rowUnits: Int
  init(bytes: UInt64, profile: String) throws {
    sourceBytes = bytes
    if bytes == 1073741824 {
      let rowBytes: [UInt8] = (0..<256).map { (index: Int) -> UInt8 in
        let byte: Int = index == 255 ? 10 : 97 + index % 26
        return UInt8(byte)
      }
      row = Data(rowBytes)
    } else {
      let prefix = profile == "markdownBoundary" ? "# **Public** café cafe\u{301} 🙂 👩‍🚀 中. " : "Public café cafe\u{301} 🙂 👩‍🚀 中. "
      var text = Data(prefix.utf8)
      let filler = Array("abcdefghijklmnopqrstuvwxyz ".utf8)
      while text.count < 255 { text.append(filler[(text.count - 1) % filler.count]) }
      text.append(10); row = text
    }
    rowText = String(decoding: row, as: UTF8.self); rowUnits = rowText.utf16.count
    try matchedRequire(row.count == 256 && rowText.utf8.count == 256, "Public period is not valid exact UTF-8.")
    let tail = Int(bytes % 256)
    try matchedRequire(String(data: row.prefix(tail), encoding: .utf8) != nil, "Public tail splits a scalar.")
  }
  func bytes(at offset: UInt64, count: Int) throws -> Data {
    let end = offset.addingReportingOverflow(UInt64(max(0, count)))
    try matchedRequire(count >= 0 && count <= 65536 && !end.overflow && end.partialValue <= sourceBytes,
      "Public oracle exceeded its bounded range.")
    var value = Data(count: count)
    value.withUnsafeMutableBytes { raw in
      let buffer = raw.bindMemory(to: UInt8.self)
      for index in 0..<count { buffer[index] = row[Int((offset + UInt64(index)) % 256)] }
    }
    return value
  }
  func units(atByte offset: UInt64) throws -> UInt64 {
    try matchedRequire(offset <= sourceBytes, "Public coordinate exceeds source.")
    let tail = Int(offset % 256)
    guard let text = String(data: row.prefix(tail), encoding: .utf8) else { throw MatchedRefusal(message: "Public coordinate splits UTF-8.") }
    return (offset / 256) * UInt64(rowUnits) + UInt64(text.utf16.count)
  }
  func write(to url: URL) throws -> String {
    try matchedRequire(!Thread.isMainThread, "Public fixture writing entered Main.")
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
      var hash = SHA256(), offset: UInt64 = 0
      while offset < sourceBytes {
        try Task.checkCancellation()
        let chunk = try bytes(at: offset, count: Int(min(UInt64(65536), sourceBytes - offset)))
        try file.write(contentsOf: chunk); hash.update(data: chunk); offset += UInt64(chunk.count)
      }
      try file.synchronize()
      var info = stat()
      try matchedRequire(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
        && info.st_size == Int64(sourceBytes), "Public fixture is not an exact regular file.")
      if sourceBytes == 1073741824 {
        try matchedRequire(info.st_blocks >= 0 && UInt64(info.st_blocks) * 512 >= sourceBytes, "Public GiB fixture is sparse.")
      }
      try file.close()
      return hash.finalize().map { String(format: "%02x", $0) }.joined()
    } catch {
      let original = error
      do { try file.close() } catch { throw MatchedRefusal(message: "Fixture failure: \(original); close refusal: \(error)") }
      throw original
    }
  }
}

private struct MatchedMemory: Codable, Sendable {
  let time: UInt64
  let rss: UInt64
  let footprint: UInt64
  let kernelLifetimePeakRSS: UInt64
  let kernelLifetimePeakFootprint: UInt64
  static func readSelf() throws -> Self {
    var info = task_vm_info_data_t(), usage = rusage()
    let words = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    var count = mach_msg_type_number_t(words)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: words) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS,
      let peak = MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak),
      Int(count) * MemoryLayout<integer_t>.size >= peak + MemoryLayout<Int64>.size,
      info.resident_size > 0 && info.phys_footprint > 0 && info.ledger_phys_footprint_peak >= 0,
      getrusage(RUSAGE_SELF, &usage) == 0 && usage.ru_maxrss > 0 else {
      throw MatchedRefusal(message: "Self memory coverage was unavailable or incomplete (\(result)).")
    }
    return Self(time: matchedNow(), rss: info.resident_size, footprint: info.phys_footprint,
      kernelLifetimePeakRSS: UInt64(usage.ru_maxrss), kernelLifetimePeakFootprint: UInt64(info.ledger_phys_footprint_peak))
  }
}
private struct MatchedCache: Codable, Sendable {
  let chargedBytes: Int
  let entries: Int
  let pageReads: UInt64
  let readBytes: UInt64
  let pageWrites: UInt64
  let cacheHits: UInt64
  init(_ value: PagedTextCacheStats) {
    chargedBytes = value.chargedBytes; entries = value.entries; pageReads = value.pageReads
    readBytes = value.readBytes; pageWrites = value.pageWrites; cacheHits = value.cacheHits
  }
  func validate() throws {
    try matchedRequire(chargedBytes >= 0 && chargedBytes <= 8 * 1048576 && entries >= 0 && entries <= 512,
      "Actual paged engine cache exceeded the qualified observed8MiB/512-entry envelope.")
  }
}
private struct MatchedStage: Codable, Sendable {
  let scheduled: UInt64
  let started: UInt64
  let ended: UInt64
}
private struct MatchedVisible: Codable, Sendable {
  let viewportWidth: Double
  let viewportHeight: Double
  let caretX: Double
  let caretY: Double
  let caretHeight: Double
  let globalVisibleStart: UInt64
  let visibleUnits: Int
  let visibleUTF8Digest: String
  let globalCaret: UInt64
  let selectionUnits: Int
}
// Failure-only values; coordinate strings retain nonfinite rectangles too.
// The array order is x, y, width, height. Encoding belongs to the journal actor.
private struct MatchedRectSnapshot: Encodable, Sendable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double
  init(_ value: NSRect) {
    x = Double(value.origin.x); y = Double(value.origin.y)
    width = Double(value.width); height = Double(value.height)
  }
  func encode(to encoder: Encoder) throws {
    var values = encoder.singleValueContainer()
    try values.encode([x, y, width, height].map { String(describing: $0) })
  }
}
private struct MatchedVisibleFailureSnapshot: Encodable, Sendable {
  let firstResponderIsEditor: Bool
  let caretIntersectsVisible: Bool
  let selectedLocation: Int
  let selectedLength: Int
  let extent: Int
  let screenCaret: MatchedRectSnapshot
  let localCaret: MatchedRectSnapshot
  let visibleRect: MatchedRectSnapshot
  let clipBounds: MatchedRectSnapshot
  let editorFrame: MatchedRectSnapshot
  let editorBounds: MatchedRectSnapshot
  let windowFrame: MatchedRectSnapshot
  let textContainerOrigin: MatchedRectSnapshot
}
private struct MatchedVisibleRefusal: Error, LocalizedError, Sendable {
  let snapshot: MatchedVisibleFailureSnapshot
  var errorDescription: String? { "Required visible caret/focus is absent." }
}

// Three first large-deletion notes retain fixed geometry values only. Getter
// work is inside the existing action/layout wall spans; encoding and IO stay
// on the existing journal after the native/visible timers and raw append.
private struct MatchedLayoutInsets: Encodable, Sendable {
  let top: Double
  let left: Double
  let bottom: Double
  let right: Double
  init(_ value: NSEdgeInsets) {
    top = Double(value.top); left = Double(value.left)
    bottom = Double(value.bottom); right = Double(value.right)
  }
}
private struct MatchedLayoutBefore: Encodable, Sendable {
  let editorFrame: MatchedRectSnapshot
  let editorBounds: MatchedRectSnapshot
  let visibleRect: MatchedRectSnapshot
  let editorMinSize: MatchedRectSnapshot
  let clipBounds: MatchedRectSnapshot
  let documentRect: MatchedRectSnapshot
  let documentVisibleRect: MatchedRectSnapshot
  let clipContentInsets: MatchedLayoutInsets
  let scrollContentInsets: MatchedLayoutInsets
  let automaticallyAdjustsContentInsets: Bool
  let hasVerticalScroller: Bool
  let autohidesScrollers: Bool
  let scrollerStyle: Int
  let textContainerInset: MatchedRectSnapshot
  let textContainerOrigin: MatchedRectSnapshot
  let textContainerSize: MatchedRectSnapshot
  let lineFragmentPadding: Double
  let selectedLocation: Int
  let selectedLength: Int
  let selectionAffinity: UInt
  let extent: Int
}
private struct MatchedLayoutCaret: Encodable, Sendable {
  let screenCaret: MatchedRectSnapshot
  let localCaret: MatchedRectSnapshot
  let textContainerOrigin: MatchedRectSnapshot
  let proposedBounds: MatchedRectSnapshot
  let constrainedBounds: MatchedRectSnapshot
  let selectedLocation: Int
  let selectedLength: Int
  let extent: Int
  let firstResponderIsEditor: Bool
}
private struct MatchedLayoutAfter: Encodable, Sendable {
  let clipBounds: MatchedRectSnapshot
  let editorFrame: MatchedRectSnapshot
  let editorBounds: MatchedRectSnapshot
  let visibleRect: MatchedRectSnapshot
  let documentRect: MatchedRectSnapshot
  let documentVisibleRect: MatchedRectSnapshot
  let textContainerOrigin: MatchedRectSnapshot
}
private struct MatchedLayoutObservation: Encodable, Sendable {
  let event: UInt64
  let operation: String
  let stratum: String
  let temperature: String
  let lane: String
  let before: MatchedLayoutBefore
  var atCaret: MatchedLayoutCaret?
  var afterScroll: MatchedLayoutAfter?
  let observerScope = "fixed Main getter snapshots inside existing wall spans; actor encoding/IO after timers; no CPU-stack attribution"
}

private struct MatchedOperation: Codable, Sendable {
  let schema = 1
  let event: UInt64
  let operation: String
  let stratum: String
  let temperature: String
  let requested: UInt64
  let entered: UInt64
  var selectionNS: UInt64 = 0
  var inputAdmissionMainNS: UInt64 = 0
  var focusMainNS: UInt64 = 0
  var postPrimitiveValidationMainNS: UInt64 = 0
  var nativeActionWallNS: UInt64 = 0
  var visibleWorkWallNS: UInt64 = 0
  var visibleValidationMainNS: UInt64 = 0
  var nativeNS: UInt64 = 0
  var nativeGroupPreparationMainNS: UInt64 = 0
  var nativeGroupCloseMainNS: UInt64 = 0
  var immediateHostLayoutNS: UInt64 = 0
  var deferredBarrierNS: UInt64 = 0
  var requiredViewportLayoutNS: UInt64 = 0
  var rasterDrawNS: UInt64 = 0
  var prepareReserveMainNS: UInt64 = 0
  var historyLookupAwaitNS: UInt64 = 0
  var prepareAwaitNS: UInt64 = 0
  var recenterAwaitNS: UInt64 = 0
  var viewConstructionMainNS: UInt64 = 0
  var bitmapConstructionMainNS: UInt64 = 0
  var requestedWindowAnchor: UInt64?
  var requestedGlobalCaret: UInt64?
  var publicationAwaitNS: UInt64 = 0
  var countersBeforeNS: UInt64 = 0
  var countersAfterNS: UInt64 = 0
  var visibleReady: UInt64?
  var sourceReady: UInt64?
  var inputAdmitted: UInt64?
  var journalBeforeNS: UInt64 = 0
  var visible: MatchedVisible?
  var cacheBefore: MatchedCache?
  var cacheAfter: MatchedCache?
  var nativeGenerationBefore: UInt64?
  var nativeGenerationAfter: UInt64?
  var pagedSealedRootBefore: String?
  var pagedSealedRootAfter: String?
  var deferred: [MatchedStage] = []
  var draws: [MatchedStage] = []
  var hookOverflow: Bool = false
  var status = "started"
  var error: String?
  var failureStage: String?
}

/// One actor-owned durable append stream. Encoding/sync/file work is outside
/// Main and the native timers. A full stream or hook loss fails explicitly.
private actor MatchedJournal {
  private let file: FileHandle
  private let visibleRefusalURL: URL
  private let layoutDirectory: URL
  private let encoder = JSONEncoder()
  private var bytes = 0
  private var lines = 0
  private var ticks = 0
  private var activeEvent: UInt64?
  private var sampledRSS: UInt64 = 0
  private var sampledFootprint: UInt64 = 0
  private var closed = false
  private var memoryFailure: String?
  private var layoutNotes = 0
  static let cap = 16 * 1048576
  init(url: URL) throws {
    visibleRefusalURL = url.deletingLastPathComponent().appendingPathComponent("visible-refusal.json")
    layoutDirectory = url.deletingLastPathComponent()
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }
  private func append<T: Encodable>(_ value: T, terminal: Bool = false) throws {
    try matchedRequire(!Thread.isMainThread && !closed, "Raw journal is closed or entered Main.")
    var data = try encoder.encode(value)
    try matchedRequire(data.count <= 8192, "Raw observation exceeds its admitted record bound.")
    data.append(10)
    try matchedRequire(data.count <= (terminal ? Self.cap : Self.cap - 65536) - bytes,
      "Raw journal cap reached; the complete prefix is preserved.")
    try file.write(contentsOf: data); bytes += data.count; lines += 1
    if lines % 16 == 0 || terminal { try file.synchronize() }
  }
  func visibleRefusal(_ snapshot: MatchedVisibleFailureSnapshot, event: UInt64) throws {
    struct Line: Encodable {
      let kind = "visible-refusal-snapshot"
      let event: UInt64
      let snapshot: MatchedVisibleFailureSnapshot
    }
    try matchedRequire(!Thread.isMainThread && !closed, "Diagnostic journal is closed or entered Main.")
    let data = try encoder.encode(Line(event: event, snapshot: snapshot))
    try matchedRequire(data.count <= 8192, "Visible refusal exceeds its existing record bound.")
    let fd = open(visibleRefusalURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let diagnostic = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
      try diagnostic.write(contentsOf: data); try diagnostic.synchronize()
      try diagnostic.close()
    } catch {
      let firstFailure = error
      do { try diagnostic.close() }
      catch { print("Matched visible diagnostic secondary close refusal retained: \(error)") }
      throw firstFailure
    }
  }
  func layoutObservation(_ value: MatchedLayoutObservation) throws {
    try matchedRequire(!Thread.isMainThread && !closed && layoutNotes < 3,
      "Layout notes are closed, on Main, or exceed their three-note bound.")
    try matchedRequire(value.operation == "large-native-delete" && value.temperature == "first-mutation-in-arena",
      "Layout note has another admitted operation.")
    let diagnosticEncoder = JSONEncoder()
    diagnosticEncoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: "+infinity", negativeInfinity: "-infinity", nan: "nan")
    let data = try diagnosticEncoder.encode(value)
    try matchedRequire(data.count <= 16384, "Layout note exceeds its16KiB encoded bound.")
    let url = layoutDirectory.appendingPathComponent("layout-observation-\(value.event).json")
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let diagnostic = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
      try diagnostic.write(contentsOf: data); try diagnostic.synchronize(); try diagnostic.close()
    } catch {
      let firstFailure = error
      do { try diagnostic.close() }
      catch { print("Matched layout diagnostic secondary close refusal retained: \(error)") }
      throw firstFailure
    }
    layoutNotes += 1
  }
  func begin(_ value: MatchedOperation) throws {
    try matchedRequire(activeEvent == nil, "Only one measured operation may be outstanding.")
    activeEvent = value.event; sampledRSS = 0; sampledFootprint = 0
    try append(value)
  }
  func end(_ value: MatchedOperation, memory: MatchedMemory?) throws {
    struct Line: Encodable {
      let kind = "operation-finished-or-partial"
      let operation: MatchedOperation
      let endingSelfMemory: MatchedMemory?
      let sampledPeakRSS: UInt64
      let sampledPeakFootprint: UInt64
      let peakScope = "sampled whole operation plus visible work, publication and counter queries; kernel peaks are process lifetime"
    }
    try matchedRequire(activeEvent == value.event, "Raw operation lost its exact producer identity.")
    if let memory { sampledRSS = max(sampledRSS, memory.rss); sampledFootprint = max(sampledFootprint, memory.footprint) }
    try append(Line(operation: value, endingSelfMemory: memory, sampledPeakRSS: sampledRSS, sampledPeakFootprint: sampledFootprint))
    activeEvent = nil
  }
  func tick(_ memory: MatchedMemory) throws {
    struct Tick: Encodable { let kind = "self-memory"; let event: UInt64?; let value: MatchedMemory }
    try matchedRequire(ticks < 12200, "Memory observer exceeded the fixed600-second tick budget.")
    ticks += 1
    if activeEvent != nil { sampledRSS = max(sampledRSS, memory.rss); sampledFootprint = max(sampledFootprint, memory.footprint) }
    try append(Tick(event: activeEvent, value: memory))
  }
  func noteMemoryFailure(_ error: String) { memoryFailure = error }
  func metadata<T: Encodable & Sendable>(_ value: T) throws { try append(value) }
  func finish(status: String, error: String?, workerJoined: Bool) throws {
    struct Terminal: Encodable {
      let kind = "terminal"
      let status: String
      let error: String?
      let activeEvent: UInt64?
      let memoryFailure: String?
      let bytes: Int
      let lines: Int
      let memoryTicks: Int
      let workerJoined: Bool
      let cpuStackCoverage = "none; durations and existing optional signposts are not sampled CPU stacks"
      let qualification = "actual Author versus qualified paged126 component with viewport adapter; no managed ordinary Undo or physical input/compositor acceptance"
    }
    if status == "complete" { try matchedRequire(layoutNotes == 3, "Complete comparison lacks its three bounded layout notes.") }
    let terminalStatus = memoryFailure == nil ? status : "incomplete-memory-observation"
    try append(Terminal(status: terminalStatus, error: error, activeEvent: activeEvent, memoryFailure: memoryFailure,
      bytes: bytes, lines: lines, memoryTicks: ticks, workerJoined: workerJoined), terminal: true)
    try file.close(); closed = true
    if let memoryFailure { throw MatchedRefusal(message: memoryFailure) }
  }
}

/// No replacement baseline: this is only the missing host for the real paged
/// component. All public typography/container changes are recorded as adapter
/// configuration; they do not pretend to be shipped ordinary paged chrome.
// Typography remains an explicit bounded fixture adapter, applied to the
// real production viewport/client. It creates no owner, view, or source copy.
@MainActor private func matchedConfigureManagedViewport(_ viewport: PagedDocumentViewport,
  editor: PagedNativeTextView, geometry: MatchedGeometry) throws {
  guard viewport.textView === editor, viewport.documentView === editor,
    let container = editor.textContainer, let storage = editor.textStorage else {
    throw MatchedRefusal(message: "Actual managed viewport lost its current client/container.")
  }
  let system = NSFont.systemFont(ofSize: geometry.fontSize)
  guard let font = system.fontName == geometry.fontName ? system : NSFont(name: geometry.fontName, size: geometry.fontSize) else {
    throw MatchedRefusal(message: "Matched typography is unavailable.")
  }
  let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = geometry.lineSpacing
  let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
  storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
  editor.typingAttributes = attributes; editor.font = font
  editor.textContainerInset = NSSize(width: geometry.insetX, height: geometry.insetY)
  container.widthTracksTextView = false; container.heightTracksTextView = false
  container.lineFragmentPadding = geometry.lineFragmentPadding
  container.size = NSSize(width: geometry.containerWidth, height: .greatestFiniteMagnitude)
  editor.isVerticallyResizable = true; editor.minSize = NSSize(width: 0, height: geometry.viewportHeight)
  editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
  editor.autoresizingMask = [.width]
  editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
  editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
  editor.isAutomaticLinkDetectionEnabled = false; editor.isContinuousSpellCheckingEnabled = true
  editor.importsGraphics = false; editor.usesFindBar = false; editor.usesFindPanel = false
  editor.drawsBackground = geometry.drawsBackground; editor.backgroundColor = BoomChrome.documentBackground
  // Reference width already excludes Author chrome. Preserve that exact clip
  // width instead of silently subtracting a second fixture scroller.
  viewport.borderType = .noBorder; viewport.hasVerticalScroller = false
}

private struct MatchedPagedSetup: Sendable {
  let engine: PagedTextEngineAdapter
  let backend: PagedNativeStorageBackend
  let vault: Vault
  let owner: UUID
  let publisher: PagedWorkspacePublisher
  let record: PagedDocumentRootRecord
  let opening: PagedNativeCanonicalOpening
  let coldCacheBeforeAdmission: MatchedCache
  let coldNativeAdmissionNS: UInt64
}
/// Custody starts before either factory can fail. The disposable diagnostic
/// process retains partial setup as well as completed views and source owners.
@MainActor private final class MatchedResources {
  var model: WorkspaceModel?
  var engine: PagedTextEngineAdapter?
  var publisher: PagedWorkspacePublisher?
  var backend: PagedNativeStorageBackend?
  var opening: PagedNativeCanonicalOpening?
  var session: PagedNativeSession?
  var input: PagedNativeInputOwner?
  var commands: PagedNativeUndoOwner?
  var sourceFile: FileHandle?
  var window: NSWindow?
  var host: NSView?
  var editor: NSTextView?
  private var received: [PagedTextRootLease] = []
  private var closed = false
  func own(_ engine: PagedTextEngineAdapter) throws {
    try matchedRequire(self.engine == nil, "Another actual engine epoch still belongs to this receiver.")
    self.engine = engine
  }
  func ownFile(_ file: FileHandle?) { sourceFile = file }
  func ownPublisher(_ publisher: PagedWorkspacePublisher) { self.publisher = publisher }
  func ownBackend(_ backend: PagedNativeStorageBackend) { self.backend = backend }
  func ownOpening(_ opening: PagedNativeCanonicalOpening) { self.opening = opening }
  func receive<T: Sendable>(_ output: PagedTextCustodiedValue<T>) throws -> T {
    guard received.count < 32 else {
      throw PagedTextCustodyFailure(original: MatchedRefusal(message: "Public matched receiver exceeds32 actual root leases; the producer remains retained."), lease: output.lease)
    }
    received.append(output.lease); return output.value
  }
  func removeReceived(_ lease: PagedTextRootLease) {
    precondition(received.contains(lease)); received.removeAll { $0 == lease }
  }
  func importerActuallyClosed(_ importer: PagedTextEngineAdapter) throws {
    try matchedRequire(engine === importer && received.isEmpty && sourceFile == nil && backend == nil,
      "The actual importer or its root/file custody did not join before cold reopen.")
    engine = nil; publisher = nil
  }
  func closePartial() async throws {
    if closed { return }
    if let file = sourceFile {
      try await Task.detached { try file.close() }.value; sourceFile = nil
    }
    if let commands { try await commands.joinPendingCommand() }
    if let session, let backend, let publisher, let engine {
      _ = try await session.flush(through: session.generation)
      let loadedOutput = try await engine.loadWorkspaceRetaining(publisher)
      let loaded = try receive(loadedOutput)
      guard loaded.documents.count == 1, let current = loaded.documents.first,
        current == session.canonicalHistory?.record,
        session.activeNavigationOperationCount == 0, !session.hasPendingHistoryCommand,
        let commands, let input else {
        throw MatchedRefusal(message: "Actual canonical source/input still needs its owner before close.")
      }
      try commands.closeInput(); try commands.requireJoinedClose()
      try input.requireJoinedClose()
      _ = window?.makeFirstResponder(nil)
      (host as? PagedDocumentViewport)?.documentView = nil
      try await backend.detachJoinedController(sessionID: session.sessionID,
        sequence: session.generation, record: current)
    } else if backend != nil || opening != nil || input != nil || commands != nil {
      throw MatchedRefusal(message: "Partial canonical installation retains its actual backend/client; no detach is inferred.")
    }
    if let engine {
      while let lease = received.first {
        try await engine.abandonJoinedRootOutput(lease); removeReceived(lease)
      }
      let wal = try await engine.joinScheduledWALMaintenance()
      if let failure = wal.failure { throw failure }
      try await engine.close()
    }
    if let model { try await model.shutdown() }
    window?.close(); closed = true
  }
}
@MainActor private final class MatchedLane {
  let recipe: MatchedRecipe
  let oracle: MatchedOracle
  let journal: MatchedJournal
  let scratch: URL
  let model: WorkspaceModel?
  let paged: MatchedPagedSetup?
  let session: PagedNativeSession?
  let input: PagedNativeInputOwner?
  let commands: PagedNativeUndoOwner?
  let resources: MatchedResources
  let window: NSWindow
  private(set) var host: NSView
  private(set) var editor: NSTextView
  private(set) var geometry: MatchedGeometry
  let initialViewMainNS: UInt64
  private var originUTF16: UInt64 = 0
  private var sizedManagedView: ObjectIdentifier?
  private var callbackMountMainNS: UInt64 = 0
  private var mountedClients = 0
  private var bitmap: NSBitmapImageRep?
  private var deferred: [MatchedStage] = []
  private var draws: [MatchedStage] = []
  private var hooksOverflow = false
  private var event: UInt64 = 0
  private(set) var completed = 0
  private var phaseFailure: Error?
  private var runDeadline: UInt64?

  private init(recipe: MatchedRecipe, oracle: MatchedOracle, journal: MatchedJournal, scratch: URL,
    model: WorkspaceModel?, paged: MatchedPagedSetup?, session: PagedNativeSession?,
    input: PagedNativeInputOwner?, commands: PagedNativeUndoOwner?, resources: MatchedResources, window: NSWindow,
    host: NSView, editor: NSTextView, geometry: MatchedGeometry, initialViewMainNS: UInt64) {
    self.recipe = recipe; self.oracle = oracle; self.journal = journal; self.scratch = scratch
    self.model = model; self.paged = paged; self.session = session
    self.input = input; self.commands = commands; self.resources = resources; self.window = window
    self.host = host; self.editor = editor; self.geometry = geometry
    self.initialViewMainNS = initialViewMainNS
    deferred.reserveCapacity(16); draws.reserveCapacity(16)
    session?.didFail = { [weak self] error in if self?.phaseFailure == nil { self?.phaseFailure = error } }
    commands?.didFail = { [weak self] error in if self?.phaseFailure == nil { self?.phaseFailure = error } }
    commands?.mountView = { [weak self] old, new in
      guard let self else {
        XCTFail("The retained public managed mount lost its actual fixture receiver.")
        throw MatchedRefusal(message: "The actual managed mount receiver is absent.")
      }
      let start = matchedNow()
      defer { self.callbackMountMainNS += matchedElapsed(start) }
      do {
        guard let viewport = self.host as? PagedDocumentViewport,
          self.editor === old, self.input?.activeView === new, self.mountedClients < 32 else {
          throw MatchedRefusal(message: "Actual managed mount lost its same viewport/client or exceeds32 clients.")
        }
        try viewport.mountManagedView(from: old, to: new)
        // Custody follows the actual already-consumed installation even if
        // bounded configuration below refuses. It never rolls the source back.
        self.editor = new; self.resources.editor = new; self.mountedClients += 1
        try matchedConfigureManagedViewport(viewport, editor: new, geometry: self.geometry)
        try self.sizeManagedViewportIfNeeded()
      } catch {
        if self.phaseFailure == nil { self.phaseFailure = error }
        throw error // actual receiving scope refuses; no raw replay grant
      }
    }
  }
  static func create(recipe: MatchedRecipe, oracle: MatchedOracle, journal: MatchedJournal,
    scratch: URL, source: URL, resources: MatchedResources) async throws -> MatchedLane {
    let window = ApplicationDelegate.workspaceWindow(frame: NSRect(x: -10000, y: -10000, width: 1190, height: 846))
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
    resources.window = window
    if recipe.lane == "author" {
      let text = try await Task.detached {
        try matchedRequire(recipe.sourceBytes <= 1048576, "Author fixture would materialize an unbounded source.")
        return String(decoding: try RegularFile(source, limit: 1048576).data(), as: UTF8.self)
      }.value
      let document = DocumentSnapshot(title: "Public native comparison", text: text)
      let store = try WorkspaceStore(rootOverride: scratch.appendingPathComponent("workspace"), testKey: matchedPublicFixtureKey())
      var state = WorkspaceState(); state.autocomplete = false; state.showChat = false
      state.documents = [DocumentIndex(id: document.id, title: document.title)]; state.selectedDocument = document.id
      try await store.save(state, documents: [document])
      let model = try await WorkspaceModel(storeOverride: store, loadModels: false)
      resources.model = model
      try matchedRequire(model.layout.isAuthor, "The actual Author layout is required; a skipped Chat layout is not a comparison.")
      var uiStart = matchedNow()
      let host = NSHostingView(rootView: WorkspaceView(model: model)); window.contentView = host
      resources.host = host
      // This first required host construction/layout is setup evidence, not a
      // discarded warm-up edit. No source mutation has happened here.
      host.layoutSubtreeIfNeeded()
      var initialUI = matchedElapsed(uiStart)
      await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
      uiStart = matchedNow()
      host.layoutSubtreeIfNeeded()
      initialUI += matchedElapsed(uiStart)
      guard let editor = model.editor, let clip = editor.enclosingScrollView?.contentView,
        let container = editor.textContainer, let font = editor.font else {
        throw MatchedRefusal(message: "Actual Author binding/viewport did not attach.")
      }
      let paragraph = editor.typingAttributes[.paragraphStyle] as? NSParagraphStyle
      resources.editor = editor
      let geometry = MatchedGeometry(viewportWidth: clip.bounds.width, viewportHeight: clip.bounds.height,
        containerWidth: container.size.width, lineFragmentPadding: container.lineFragmentPadding,
        insetX: editor.textContainerInset.width, insetY: editor.textContainerInset.height,
        fontName: font.fontName, fontSize: font.pointSize, lineSpacing: Double(paragraph?.lineSpacing ?? 0),
        drawsBackground: editor.drawsBackground)
      try geometry.validate()
      if let admitted = recipe.geometry { try matchedRequire(admitted == geometry, "Actual Author viewport differs from the admitted matched reference.") }
      let result = MatchedLane(recipe: recipe, oracle: oracle, journal: journal, scratch: scratch,
        model: model, paged: nil, session: nil, input: nil, commands: nil, resources: resources,
        window: window, host: host, editor: editor, geometry: geometry,
        initialViewMainNS: initialUI)
      result.installObservers()
      return result
    }
    let setup = try await Task.detached {
      let owner = UUID(), vault = try Vault(root: scratch.appendingPathComponent("workspace"), testKey: matchedPublicFixtureKey())
      let storeID = UUID()
      let importer = try await PagedTextEngineAdapter.create(vault: vault, ownerID: owner, sqliteOpening: .fresh(storeID: storeID))
      try await resources.own(importer)
      let file = try FileHandle(forReadingFrom: source); await resources.ownFile(file)
      let importedOutput = try await importer.importUTF8Retaining(documentID: UUID(), from: file)
      let imported = try await resources.receive(importedOutput)
      try file.close(); await resources.ownFile(nil)
      let document = PagedDocumentDescriptor(id: imported.revision.documentID, title: "Public native comparison", revision: imported.revision)
      let initialOutput = try await importer.initialNativeRecordRetaining(document)
      let record = try await resources.receive(initialOutput)
      let publisher = try await importer.makeWorkspacePublisher(); await resources.ownPublisher(publisher)
      var state = WorkspaceState(); state.documents = [DocumentIndex(id: document.id, title: document.title)]; state.selectedDocument = document.id
      let savedOutput = try await importer.initializeWorkspaceRetaining(publisher, state: state, documents: [record])
      _ = try await resources.receive(savedOutput)
      try await importer.finishWorkspacePublication(savedOutput, publisher: publisher)
      try await importer.transferJoinedRootToHead(importedOutput.lease, publisher: publisher, expected: record)
      await resources.removeReceived(importedOutput.lease)
      try await importer.transferJoinedRootToHead(initialOutput.lease, publisher: publisher, expected: record)
      await resources.removeReceived(initialOutput.lease)
      try await importer.abandonJoinedRootOutput(savedOutput.lease); await resources.removeReceived(savedOutput.lease)
      let importWAL = try await importer.joinScheduledWALMaintenance()
      if let failure = importWAL.failure { throw failure }
      try await importer.close(); try await resources.importerActuallyClosed(importer)
      let coldStart = matchedNow(), engine = try await PagedTextEngineAdapter.create(vault: vault, ownerID: owner, sqliteOpening: .existing(storeID: storeID))
      try await resources.own(engine)
      let cold = MatchedCache(try await engine.stats()); try cold.validate()
      try matchedRequire(cold.pageReads == 0 && cold.readBytes == 0 && cold.chargedBytes == 0,
        "The reopened pager did not begin with a new cold engine source cache.")
      let reopenedPublisher = try await engine.makeWorkspacePublisher(); await resources.ownPublisher(reopenedPublisher)
      let loadedOutput = try await engine.loadWorkspaceRetaining(reopenedPublisher)
      let head = try await resources.receive(loadedOutput)
      try matchedRequire(head.documents.count == 1 && head.documents.first == record,
        "Cold admission changed its exact authenticated root/history record.")
      let backend = try await engine.makeNativeStorage(reopenedPublisher, expected: record); await resources.ownBackend(backend)
      let opening = try await backend.opening(sessionID: UUID()); await resources.ownOpening(opening)
      try await engine.abandonJoinedRootOutput(loadedOutput.lease); await resources.removeReceived(loadedOutput.lease)
      return MatchedPagedSetup(engine: engine, backend: backend, vault: vault, owner: owner,
        publisher: reopenedPublisher, record: record, opening: opening, coldCacheBeforeAdmission: cold,
        coldNativeAdmissionNS: matchedElapsed(coldStart))
    }.value
    let uiStart = matchedNow()
    let session = try PagedNativeSession(opening: setup.opening, storage: setup.backend); resources.session = session
    let geometry = recipe.geometry!
    let input = try PagedNativeInputOwner(frame: NSRect(x: 0, y: 0, width: geometry.viewportWidth, height: geometry.viewportHeight), session: session)
    resources.input = input
    let commands = try PagedNativeUndoOwner(input: input); resources.commands = commands
    guard let editor = input.activeView else { throw MatchedRefusal(message: "Canonical native opening lost its actual client.") }
    resources.editor = editor
    let viewport = try PagedDocumentViewport(frame: NSRect(x: 0, y: 0, width: geometry.viewportWidth, height: geometry.viewportHeight), input: input)
    resources.host = viewport
    try matchedConfigureManagedViewport(viewport, editor: editor, geometry: geometry)
    window.setContentSize(NSSize(width: geometry.viewportWidth, height: geometry.viewportHeight)); window.contentView = viewport
    return MatchedLane(recipe: recipe, oracle: oracle, journal: journal, scratch: scratch,
      model: nil, paged: setup, session: session, input: input, commands: commands, resources: resources,
      window: window, host: viewport, editor: editor, geometry: geometry,
      initialViewMainNS: matchedElapsed(uiStart))
  }
  private func sizeManagedViewportIfNeeded() throws {
    guard let viewport = host as? PagedDocumentViewport else { return }
    guard let native = editor as? PagedNativeTextView, viewport.textView === native,
      viewport.documentView === native, input?.activeView === native else {
      throw MatchedRefusal(message: "Bounded sizing lost the actual managed viewport/client.")
    }
    let inset = NSSize(width: geometry.insetX, height: geometry.insetY)
    let height = max(1, geometry.viewportHeight)
    let identifier = ObjectIdentifier(native)
    let changed = sizedManagedView != identifier || native.frame.width != geometry.viewportWidth
      || native.textContainerInset != inset || native.minSize.height != height
    guard changed else { return }
    native.textContainerInset = inset; native.minSize = NSSize(width: 0, height: height)
    native.setFrameSize(NSSize(width: geometry.viewportWidth, height: max(height, native.frame.height)))
    native.sizeToFit(); sizedManagedView = identifier
  }
  private func installObservers() {
    guard let editor = editor as? MarkdownTextView else { return }
    editor.deferredLayoutObservation = { [weak self] scheduled, start, end in
      guard let self else { return }
      let anchor = ContinuousClock().now, ns = matchedNow()
      func stamp(_ instant: ContinuousClock.Instant) -> UInt64? {
        let difference = instant.duration(to: anchor).timeInterval
        guard difference.isFinite, difference >= 0, difference * 1000000000 <= Double(ns) else { return nil }
        return ns - UInt64(difference * 1000000000)
      }
      guard self.deferred.count < 16, let a = stamp(scheduled), let b = stamp(start), let c = stamp(end) else {
        self.hooksOverflow = true; return
      }
      self.deferred.append(MatchedStage(scheduled: a, started: b, ended: c))
    }
    editor.drawObservation = { [weak self] start, end in
      guard let self else { return }
      let anchor = ContinuousClock().now, ns = matchedNow()
      let a = start.duration(to: anchor).timeInterval, b = end.duration(to: anchor).timeInterval
      guard self.draws.count < 16, a.isFinite, b.isFinite, a >= 0, b >= 0,
        a * 1000000000 <= Double(ns), b * 1000000000 <= Double(ns) else { self.hooksOverflow = true; return }
      self.draws.append(MatchedStage(scheduled: ns - UInt64(a * 1000000000),
        started: ns - UInt64(a * 1000000000), ended: ns - UInt64(b * 1000000000)))
    }
  }
  private func prepareBitmap(_ observation: inout MatchedOperation?) throws {
    let start = matchedNow()
    let scale = window.backingScaleFactor
    try matchedRequire(scale.isFinite && scale >= 1 && scale <= 2,
      "Display scale is outside the explicitly admitted first raster comparison.")
    let requested = ceil(geometry.viewportWidth * scale) * ceil(geometry.viewportHeight * scale) * 8
    try matchedRequire(requested <= 32 * 1048576, "Requested raster envelope exceeds32MiB before allocation.")
    guard let next = editor.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0,
      width: geometry.viewportWidth, height: geometry.viewportHeight)) else {
      throw MatchedRefusal(message: "Bounded raster backing is unavailable.")
    }
    let cost = next.bytesPerRow.multipliedReportingOverflow(by: next.pixelsHigh)
    try matchedRequire(next.bytesPerRow > 0 && next.pixelsHigh > 0 && !cost.overflow && cost.partialValue <= 32 * 1048576,
      "Native raster backing exceeded its fixed32MiB admitted bound.")
    bitmap = next
    observation?.bitmapConstructionMainNS = matchedElapsed(start)
  }
  private func range(_ global: UInt64, length: Int) throws -> NSRange {
    try matchedRequire(global >= originUTF16 && global - originUTF16 <= UInt64(Int.max), "Global caret is outside its physical arena.")
    let local = Int(global - originUTF16)
    try matchedRequire(length >= 0 && local <= (editor.textStorage?.length ?? 0)
      && length <= (editor.textStorage?.length ?? 0) - local, "Operation range would cross the native island; no fallback is permitted.")
    return NSRange(location: local, length: length)
  }
  private func layoutBefore(_ observation: MatchedOperation) throws -> MatchedLayoutObservation {
    guard let scroll = editor.enclosingScrollView, let container = editor.textContainer else {
      throw MatchedRefusal(message: "Bounded layout observation has no actual viewport owner.")
    }
    let clip = scroll.contentView, selected = editor.selectedRange()
    let before = MatchedLayoutBefore(editorFrame: MatchedRectSnapshot(editor.frame),
      editorBounds: MatchedRectSnapshot(editor.bounds), visibleRect: MatchedRectSnapshot(editor.visibleRect),
      editorMinSize: MatchedRectSnapshot(NSRect(origin: .zero, size: editor.minSize)),
      clipBounds: MatchedRectSnapshot(clip.bounds), documentRect: MatchedRectSnapshot(clip.documentRect),
      documentVisibleRect: MatchedRectSnapshot(clip.documentVisibleRect),
      clipContentInsets: MatchedLayoutInsets(clip.contentInsets), scrollContentInsets: MatchedLayoutInsets(scroll.contentInsets),
      automaticallyAdjustsContentInsets: scroll.automaticallyAdjustsContentInsets,
      hasVerticalScroller: scroll.hasVerticalScroller, autohidesScrollers: scroll.autohidesScrollers,
      scrollerStyle: scroll.scrollerStyle.rawValue,
      textContainerInset: MatchedRectSnapshot(NSRect(origin: .zero, size: editor.textContainerInset)),
      textContainerOrigin: MatchedRectSnapshot(NSRect(origin: editor.textContainerOrigin, size: .zero)),
      textContainerSize: MatchedRectSnapshot(NSRect(origin: .zero, size: container.size)),
      lineFragmentPadding: Double(container.lineFragmentPadding), selectedLocation: selected.location,
      selectedLength: selected.length, selectionAffinity: editor.selectionAffinity.rawValue,
      extent: editor.textStorage?.length ?? 0)
    return MatchedLayoutObservation(event: observation.event, operation: observation.operation,
      stratum: observation.stratum, temperature: observation.temperature, lane: recipe.lane, before: before)
  }
  private func visibleWork(_ observation: inout MatchedOperation,
    layoutObservation: inout MatchedLayoutObservation?) async throws {
    let visibleStart = matchedNow()
    defer { observation.visibleWorkWallNS = matchedElapsed(visibleStart) }
    var start = matchedNow(); host.layoutSubtreeIfNeeded(); try sizeManagedViewportIfNeeded(); observation.immediateHostLayoutNS = matchedElapsed(start)
    start = matchedNow()
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    observation.deferredBarrierNS = matchedElapsed(start)
    start = matchedNow()
    host.layoutSubtreeIfNeeded(); try sizeManagedViewportIfNeeded()
    guard let manager = editor.layoutManager, let container = editor.textContainer,
      let clip = editor.enclosingScrollView?.contentView else { throw MatchedRefusal(message: "Visible native layout ownership is missing.") }
    let selected = editor.selectedRange()
    let extent = editor.textStorage?.length ?? 0
    try matchedRequire(selected.location >= 0 && selected.length >= 0 && selected.location <= extent
      && selected.length <= extent - selected.location, "Actual native selection is outside its bounded extent.")
    manager.ensureLayout(forCharacterRange: NSRange(location: selected.location, length: min(1, extent - selected.location)))
    editor.scrollRangeToVisible(selected)
    let screenCaret = editor.firstRect(forCharacterRange: selected, actualRange: nil)
    guard screenCaret.origin.x.isFinite && screenCaret.origin.y.isFinite
      && screenCaret.width.isFinite && screenCaret.height.isFinite && screenCaret.height > 0 else {
      throw MatchedRefusal(message: "Actual native caret rectangle is non-finite or has no positive line height; "
        + "screenCaret=\(screenCaret), clipBounds=\(clip.bounds), editorBounds=\(editor.bounds), "
        + "selected=\(selected), extent=\(extent), firstResponderIsEditor=\(window.firstResponder === editor).")
    }
    let localCaret = editor.convert(window.convertFromScreen(screenCaret), from: nil)
    var proposedBounds = clip.bounds
    proposedBounds.origin = NSPoint(x: 0, y: max(0, localCaret.minY - 64))
    let constrainedBounds = clip.constrainBoundsRect(proposedBounds)
    if layoutObservation != nil {
      layoutObservation?.atCaret = MatchedLayoutCaret(screenCaret: MatchedRectSnapshot(screenCaret),
        localCaret: MatchedRectSnapshot(localCaret),
        textContainerOrigin: MatchedRectSnapshot(NSRect(origin: editor.textContainerOrigin, size: .zero)),
        proposedBounds: MatchedRectSnapshot(proposedBounds), constrainedBounds: MatchedRectSnapshot(constrainedBounds),
        selectedLocation: selected.location, selectedLength: selected.length, extent: extent,
        firstResponderIsEditor: window.firstResponder === editor)
    }
    clip.scroll(to: constrainedBounds.origin); editor.enclosingScrollView?.reflectScrolledClipView(clip)
    let visible = editor.visibleRect
    if layoutObservation != nil {
      layoutObservation?.afterScroll = MatchedLayoutAfter(clipBounds: MatchedRectSnapshot(clip.bounds),
        editorFrame: MatchedRectSnapshot(editor.frame), editorBounds: MatchedRectSnapshot(editor.bounds),
        visibleRect: MatchedRectSnapshot(visible), documentRect: MatchedRectSnapshot(clip.documentRect),
        documentVisibleRect: MatchedRectSnapshot(clip.documentVisibleRect),
        textContainerOrigin: MatchedRectSnapshot(NSRect(origin: editor.textContainerOrigin, size: .zero)))
    }
    manager.ensureLayout(forBoundingRect: visible.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y), in: container)
    if !(visible.intersects(localCaret) && window.firstResponder === editor) {
      // Read already-computed geometry and identity only on this refusal.
      // No extra layout, focus handoff, caret query, or successful-path work.
      throw MatchedVisibleRefusal(snapshot: MatchedVisibleFailureSnapshot(
        firstResponderIsEditor: window.firstResponder === editor, caretIntersectsVisible: visible.intersects(localCaret),
        selectedLocation: selected.location, selectedLength: selected.length, extent: extent,
        screenCaret: MatchedRectSnapshot(screenCaret), localCaret: MatchedRectSnapshot(localCaret),
        visibleRect: MatchedRectSnapshot(visible), clipBounds: MatchedRectSnapshot(clip.bounds),
        editorFrame: MatchedRectSnapshot(editor.frame), editorBounds: MatchedRectSnapshot(editor.bounds),
        windowFrame: MatchedRectSnapshot(window.frame),
        textContainerOrigin: MatchedRectSnapshot(NSRect(origin: editor.textContainerOrigin, size: .zero))))
    }
    let glyphs = manager.glyphRange(forBoundingRect: visible.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y), in: container)
    let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    try matchedRequire(characters.location >= 0 && characters.length >= 0 && characters.location <= extent
      && characters.length <= extent - characters.location && characters.length <= 4096,
      "Visible validation would exceed its admitted native range.")
    observation.requiredViewportLayoutNS = matchedElapsed(start)
    start = matchedNow()
    guard let bitmap else { throw MatchedRefusal(message: "Bounded raster backing was not prepared.") }
    editor.cacheDisplay(in: visible, to: bitmap)
    observation.rasterDrawNS = matchedElapsed(start); observation.visibleReady = matchedNow()
    // Bounded visual content validation occurs after native/layout/draw timers.
    start = matchedNow()
    let fragment = editor.textStorage?.attributedSubstring(from: characters).string ?? ""
    observation.visible = MatchedVisible(viewportWidth: visible.width, viewportHeight: visible.height,
      caretX: localCaret.minX - visible.minX, caretY: localCaret.minY - visible.minY, caretHeight: localCaret.height,
      globalVisibleStart: originUTF16 + UInt64(characters.location), visibleUnits: characters.length,
      visibleUTF8Digest: Digest.sha256(Data(fragment.utf8)), globalCaret: originUTF16 + UInt64(selected.location),
      selectionUnits: selected.length)
    observation.visibleValidationMainNS = matchedElapsed(start)
  }
  func measure(name: String, stratum: String, temperature: String,
    action: (inout MatchedOperation) async throws -> Void) async throws {
    try matchedRequire(runDeadline.map { matchedNow() < $0 } ?? false,
      "Native comparison deadline expired before the next operation; partial prefix retained.")
    try matchedRequire(event < 512, "Measured operation count exceeds its fixed bound.")
    event += 1; deferred.removeAll(keepingCapacity: true); draws.removeAll(keepingCapacity: true); hooksOverflow = false
    let requested = matchedNow()
    var observation = MatchedOperation(event: event, operation: name, stratum: stratum, temperature: temperature,
      requested: requested, entered: matchedNow())
    let journalStart = matchedNow(); try await journal.begin(observation); observation.journalBeforeNS = matchedElapsed(journalStart)
    var stage = "counter-before"
    var failure: Error?
    var layoutObservation: MatchedLayoutObservation?
    let retainLayout = name == "large-native-delete" && temperature == "first-mutation-in-arena"
    do {
      if let paged {
        let start = matchedNow(); observation.cacheBefore = MatchedCache(try await paged.engine.stats())
        observation.countersBeforeNS = matchedElapsed(start); try observation.cacheBefore?.validate()
      }
      observation.nativeGenerationBefore = session?.generation
      observation.pagedSealedRootBefore = session?.sealedRevision.root?.page.digest
      observation.inputAdmitted = matchedNow()
      stage = "native-action"
      do {
        let start = matchedNow(); defer { observation.nativeActionWallNS = matchedElapsed(start) }
        if retainLayout { layoutObservation = try layoutBefore(observation) }
        try await action(&observation)
      }
      stage = "required-visible-layout-draw"; try await visibleWork(&observation, layoutObservation: &layoutObservation)
      stage = "source-publication-or-save"
      do {
        let start = matchedNow(); defer { observation.publicationAwaitNS = matchedElapsed(start) }
        try await joinHistoryBeforeOrdinaryFlush()
        if let session { _ = try await session.flush(through: session.generation) }
        if let model { try await model.flush() }
      }
      observation.sourceReady = matchedNow()
      observation.nativeGenerationAfter = session?.generation
      observation.pagedSealedRootAfter = session?.sealedRevision.root?.page.digest
      if let paged {
        let start = matchedNow(); observation.cacheAfter = MatchedCache(try await paged.engine.stats())
        observation.countersAfterNS = matchedElapsed(start); try observation.cacheAfter?.validate()
      }
      if let phaseFailure { throw phaseFailure }
      if let failure = (editor as? PagedNativeTextView)?.boundedStorage.mutationFailure { throw failure }
      try matchedRequire(!hooksOverflow && !(editor as? MarkdownTextView != nil && draws.isEmpty), "Native attribution hook coverage was incomplete.")
      observation.deferred = deferred; observation.draws = draws; observation.hookOverflow = hooksOverflow
      try matchedRequire(runDeadline.map { matchedNow() < $0 } ?? false,
        "Native comparison deadline expired after this operation; its measured stages are preserved.")
      observation.status = "complete"
    } catch {
      failure = error
      observation.status = "partial"; observation.error = error.localizedDescription; observation.failureStage = stage
      observation.deferred = deferred; observation.draws = draws; observation.hookOverflow = hooksOverflow
    }
    var memory: MatchedMemory?
    do { memory = try await Task.detached { try MatchedMemory.readSelf() }.value }
    catch {
      await journal.noteMemoryFailure(error.localizedDescription)
      if failure == nil {
        failure = error; observation.status = "partial"
        observation.error = error.localizedDescription; observation.failureStage = "ending-self-memory"
      }
    }
    // Even an unavailable memory counter cannot discard an admitted native
    // operation's stages. A failed append leaves the exact durable prefix.
    do { try await journal.end(observation, memory: memory) }
    catch {
      if let failure { throw MatchedRefusal(message: "Operation refusal: \(failure); raw append refusal: \(error)") }
      throw error
    }
    if let refusal = failure as? MatchedVisibleRefusal {
      // Timers have returned and the partial operation is already appended.
      // Keep this bounded separate file outside the unchanged raw schema.
      do { try await journal.visibleRefusal(refusal.snapshot, event: observation.event) }
      catch { print("Matched visible diagnostic refusal retained: \(error)") }
    }
    if let layoutObservation {
      do { try await journal.layoutObservation(layoutObservation) }
      catch {
        if failure == nil { throw error }
        print("Matched layout diagnostic refusal retained after original operation failure: \(error)")
      }
    }
    if let failure { throw failure }
    completed += 1
  }
  func edit(global: UInt64, length: Int, text: String, observation: inout MatchedOperation) throws {
    observation.requestedGlobalCaret = global
    var start = matchedNow()
    let replacement = try range(global, length: length), oldLength = editor.textStorage?.length ?? 0
    observation.inputAdmissionMainNS = matchedElapsed(start)
    start = matchedNow(); editor.setSelectedRange(replacement); observation.selectionNS = matchedElapsed(start)
    start = matchedNow()
    // The real managed TextView captures/closes its own actual outer input command.
    let manager = (editor as? MarkdownTextView)?.documentUndo
    if manager != nil { editor.breakUndoCoalescing() }
    manager?.beginUndoGrouping()
    observation.nativeGroupPreparationMainNS = matchedElapsed(start)
    start = matchedNow(); editor.insertText(text, replacementRange: replacement); observation.nativeNS = matchedElapsed(start)
    start = matchedNow()
    manager?.endUndoGrouping()
    if manager != nil { editor.breakUndoCoalescing() }
    observation.nativeGroupCloseMainNS = matchedElapsed(start)
    start = matchedNow(); defer { observation.postPrimitiveValidationMainNS = matchedElapsed(start) }
    try matchedRequire(editor.textStorage?.length == oldLength - length + text.utf16.count,
      "Actual accepted primitive did not produce its exact bounded extent.")
  }
  func recenter(windowAnchor: UInt64, caret global: UInt64, observation: inout MatchedOperation) async throws {
    observation.requestedWindowAnchor = windowAnchor; observation.requestedGlobalCaret = global
    if let commands, let input {
      let previous = editor, previousHost = host
      callbackMountMainNS = 0
      let source: PagedTextWindow
      do {
        let start = matchedNow(); defer { observation.recenterAwaitNS = matchedElapsed(start) }
        source = try await commands.navigate(toUTF16: windowAnchor,
          selectingUTF16: PagedNativeNavigationSelection(utf16Offset: global, utf16Length: 0))
      }
      if let phaseFailure { throw phaseFailure }
      originUTF16 = source.utf16Start
      try matchedRequire(host === previousHost && input.activeView === editor,
        "Managed navigation changed its actual input/viewport owner.")
      observation.viewConstructionMainNS = callbackMountMainNS
      if editor !== previous {
        var optional: MatchedOperation? = observation; try prepareBitmap(&optional); observation = optional!
      } else {
        try matchedRequire(callbackMountMainNS == 0 && bitmap != nil,
          "Joined window reuse reconstructed its physical client or lost its existing bitmap.")
      }
      do {
        let start = matchedNow(); defer { observation.focusMainNS = matchedElapsed(start) }
        try matchedRequire(window.isKeyWindow && window.firstResponder === editor,
          "Actual managed navigation lost its original key-window/focus ownership.")
      }
      let start = matchedNow(); defer { observation.selectionNS = matchedElapsed(start) }
      let expectedSelection = try range(global, length: 0)
      try matchedRequire(editor.selectedRange() == expectedSelection,
        "Actual managed navigation did not retain its typed global caret.")
    } else {
      do {
        let start = matchedNow(); defer { observation.focusMainNS = matchedElapsed(start) }
        try matchedRequire(window.makeFirstResponder(editor), "Native recenter did not acquire the actual client.")
      }
      let start = matchedNow(); editor.setSelectedRange(try range(global, length: 0)); observation.selectionNS = matchedElapsed(start)
    }
  }
  func history(redo: Bool, observation: inout MatchedOperation) async throws {
    if let commands, let input, let session {
      let previous = editor
      callbackMountMainNS = 0
      var start = matchedNow()
      let manager = commands.manager
      try matchedRequire(redo ? manager.canRedo : manager.canUndo, "Actual canonical Foundation history top is absent.")
      observation.historyLookupAwaitNS = matchedElapsed(start)
      start = matchedNow(); if redo { manager.redo() } else { manager.undo() }; observation.nativeNS = matchedElapsed(start)
      do {
        start = matchedNow(); defer { observation.prepareAwaitNS = matchedElapsed(start) }
        try await commands.joinPendingCommand()
      }
      if let phaseFailure { throw phaseFailure }
      let installed = try session.windowForNativeInstallation()
      originUTF16 = installed.utf16Start
      try matchedRequire(input.activeView === editor && window.firstResponder === editor,
        "Actual canonical history lost its installed physical client/focus.")
      observation.viewConstructionMainNS = callbackMountMainNS
      if editor !== previous {
        var optional: MatchedOperation? = observation; try prepareBitmap(&optional); observation = optional!
      }
    } else {
      guard let manager = (editor as? MarkdownTextView)?.documentUndo else { throw MatchedRefusal(message: "Actual Author UndoManager is absent.") }
      try matchedRequire(redo ? manager.canRedo : manager.canUndo, "Actual Author history top is absent.")
      let start = matchedNow(); if redo { manager.redo() } else { manager.undo() }; observation.nativeNS = matchedElapsed(start)
    }
  }
  func joinHistoryBeforeOrdinaryFlush() async throws {
    if let commands { try await commands.joinPendingCommand() }
  }
  func run() async throws {
    struct Setup: Encodable, Sendable {
      let kind = "native-geometry-and-source-scope"
      let recipe: MatchedRecipe
      let geometry: MatchedGeometry
      let coldCacheBeforeAdmission: MatchedCache?
      let coldNativeAdmissionNS: UInt64?
      let initialViewMainNS: UInt64
      let initialBitmapMainNS: UInt64
      let initialKeyAndFocusMainNS: UInt64
      let initialHostLayoutMainNS: UInt64
      let authorBinding = "WorkspaceStore→WorkspaceModel(loadModels:false)→WorkspaceView→MarkdownTextView; autocomplete disabled"
      let pagerBinding = "actual retained Engine/Publisher/Backend canonical opening→Session→InputOwner→UndoOwner/Foundation manager→PagedDocumentViewport; same owners across navigation/history"
      let managedTimerScope = "viewConstructionMainNS is actual mount/typography/guarded-sizing callback time; real client construction/selection/worker joins remain in recenterAwaitNS or prepareAwaitNS and nativeActionWallNS; selectionNS after managed navigation is typed-caret validation"
      let coldDefinition = "fresh process and pager engine source-cache admission; first mutation means first at this stratum after required paint, not guaranteed empty renderer/OS caches; no purge or discarded warm-up edits"
      let scope = "required cached native raster draw, not physical input or compositor presentation; default product style/spellcheck costs retained"
    }
    let focusStart = matchedNow()
    window.makeKeyAndOrderFront(nil)
    try matchedRequire(window.isKeyWindow && window.makeFirstResponder(editor) && window.firstResponder === editor,
      "The actual native editor could not acquire key-window/focus ownership.")
    let initialFocus = matchedElapsed(focusStart)
    let layoutStart = matchedNow(); host.layoutSubtreeIfNeeded(); try sizeManagedViewportIfNeeded()
    let initialLayout = matchedElapsed(layoutStart)
    let bitmapStart = matchedNow()
    var unmeasured: MatchedOperation? = nil; try prepareBitmap(&unmeasured)
    let bitmapElapsed = matchedElapsed(bitmapStart)
    try await journal.metadata(Setup(recipe: recipe, geometry: geometry,
      coldCacheBeforeAdmission: paged?.coldCacheBeforeAdmission, coldNativeAdmissionNS: paged?.coldNativeAdmissionNS,
      initialViewMainNS: initialViewMainNS, initialBitmapMainNS: bitmapElapsed,
      initialKeyAndFocusMainNS: initialFocus, initialHostLayoutMainNS: initialLayout))
    let started = matchedNow(), rows = oracle.sourceBytes / 256
    let deadline = started.addingReportingOverflow(600000000000)
    try matchedRequire(!deadline.overflow, "Native comparison clock extent is exhausted.")
    runDeadline = deadline.partialValue
    let carets: [(String, UInt64)] = [("head", min(2, rows - 1)), ("middle", rows / 2), ("tail", rows - 3)]
    for (stratum, caretRow) in carets {
      // Preserve context on both sides of the visible caret. A recenter that
      // selects the very first island character cannot match Author's prior
      // lines; a forward8KiB deletion also needs surviving visible tail text.
      let anchorRow = min(caretRow > 16 ? caretRow - 16 : 0, rows > 64 ? rows - 64 : 0)
      let byteAnchor = anchorRow * 256
      let anchor = try oracle.units(atByte: byteAnchor)
      let caret = try oracle.units(atByte: caretRow * 256)
      try await measure(name: "navigate-and-construct-viewport", stratum: stratum, temperature: "first-in-arena") { value in
        try await self.recenter(windowAnchor: anchor, caret: caret, observation: &value)
      }
      // Every batch starts from the same public period. The native 8KiB
      // deletion is admitted only where the16KiB actual island can contain it.
      let deleteRows = min(UInt64(32), rows >= 64 ? UInt64(32) : max(1, rows / 2))
      let deleteStartRow = rows - caretRow >= deleteRows ? caretRow : caretRow - deleteRows
      let deleteCaret = try oracle.units(atByte: deleteStartRow * 256)
      let original = try oracle.bytes(at: deleteStartRow * 256, count: Int(deleteRows * 256))
      let originalText = String(decoding: original, as: UTF8.self)
      let smallUnicodeRange: NSRange
      let smallUnicodeText: String
      if oracle.sourceBytes == 1073741824 {
        smallUnicodeRange = NSRange(location: 0, length: 2); smallUnicodeText = String(oracle.rowText.prefix(2))
      } else {
        smallUnicodeRange = (oracle.rowText as NSString).range(of: "🙂", options: .literal); smallUnicodeText = "🙂"
      }
      for repetition in 0..<recipe.repetitions {
        try matchedRequire(matchedElapsed(started) < 600000000000, "Native comparison exceeded its600-second bound; partial prefix retained.")
        let temperature = repetition == 0 ? "first-mutation-in-arena" : "warm"
        for (name, length, replacement) in [("type", 0, "x"), ("small-delete", 1, ""),
          ("unicode-replace", 1, "e\u{301}"), ("unicode-restore", 2, String(oracle.rowText.prefix(1))),
          ("unicode-small-delete", smallUnicodeRange.length, ""), ("unicode-small-restore", 0, smallUnicodeText),
          ("large-native-delete", originalText.utf16.count, ""), ("large-native-restore", 0, originalText)] {
          try await measure(name: name, stratum: stratum, temperature: temperature) { value in
            let position = name.hasPrefix("large-native") ? deleteCaret
              : name.hasPrefix("unicode-small") ? caret + UInt64(smallUnicodeRange.location) : caret
            try self.edit(global: position,
              length: length, text: replacement, observation: &value)
          }
        }
      }
      try await measure(name: "history-setup-type", stratum: stratum, temperature: "warm") { value in
        try self.edit(global: caret, length: 0, text: "u", observation: &value)
      }
      for redo in [false, true] {
        try await measure(name: redo ? "redo" : "undo", stratum: stratum, temperature: "first-history-move") { value in
          try await self.history(redo: redo, observation: &value)
        }
      }
      try await measure(name: "history-cleanup-delete", stratum: stratum, temperature: "warm") { value in
        try self.edit(global: caret, length: 1, text: "", observation: &value)
      }
      // A boundary request is real navigation plus actual source/projection
      // construction, never a skipped edit on a guessed rebased old view.
      let nextAnchorRow = rows > 64 ? min(rows - 64, anchorRow + 64) : 0
      let nextCaretRow = rows > 64 ? min(rows - 3, nextAnchorRow + 16) : min(rows - 3, caretRow + 1)
      let boundaryName = nextAnchorRow == anchorRow ? "boundary-clamped-recenter" : "boundary-recenter"
      try await measure(name: boundaryName, stratum: stratum, temperature: "first-in-arena") { value in
        try await self.recenter(windowAnchor: try self.oracle.units(atByte: nextAnchorRow * 256),
          caret: try self.oracle.units(atByte: nextCaretRow * 256), observation: &value)
      }
    }
  }
  func close() async throws {
    if let author = editor as? MarkdownTextView { author.deferredLayoutObservation = nil; author.drawObservation = nil }
    try await resources.closePartial()
  }
  func verifyRestoredSource(expectedSHA256: String) async throws {
    let start = matchedNow(), actual: String
    if let session, let paged {
      actual = try await paged.engine.wholeTextSha256(session.sealedRevision)
    } else if let model {
      guard let source = model.selectedDocument?.text else { throw MatchedRefusal(message: "Actual Author model source is absent.") }
      let native = editor.string
      actual = try await Task.detached {
        try matchedRequire(source.utf8.count <= 1048576 && native.utf8.count <= 1048576,
          "Final Author validation exceeded its independently bounded source.")
        let hash = Digest.sha256(Data(source.utf8))
        try matchedRequire(hash == Digest.sha256(Data(native.utf8)), "Actual Author binding/source changed across the measured sequence.")
        return hash
      }.value
    } else { throw MatchedRefusal(message: "Source verification has no retained owner.") }
    struct Integrity: Encodable, Sendable {
      let kind = "post-run-whole-source-integrity"
      let actualSHA256: String
      let expectedSHA256: String
      let elapsedNS: UInt64
      let scope = "after all operation timers; paged source uses real bounded stream, Author is capped at1MiB"
    }
    try await journal.metadata(Integrity(actualSHA256: actual, expectedSHA256: expectedSHA256, elapsedNS: matchedElapsed(start)))
    try matchedRequire(actual == expectedSHA256, "The matched operation sequence failed to restore exact public UTF-8.")
  }
}

@MainActor final class MatchedNativeEditorLatencyTests: XCTestCase {
  private static var retainedFixture: MatchedLane?
  private static var retainedResources: MatchedResources?
  func testExplicitOwnedPublicNativeComparison() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let recipePath = environment["BLOOM_NATIVE_MATCHED_RECIPE"], let outputPath = environment["BLOOM_NATIVE_MATCHED_OUTPUT"] else {
      throw XCTSkip("The matched native comparison needs one explicit owned public recipe/process.")
    }
    try matchedRequire(Self.retainedFixture == nil && Self.retainedResources == nil, "This process already owns a terminal fixture.")
    try matchedRequire(environment["BLOOM_PERFORMANCE_TRACE"] != "1", "The first matched timing gate excludes profiler/signpost runs; diagnostic capture is separate.")
    let recipe = try await Task.detached {
      let data = try RegularFile(URL(fileURLWithPath: recipePath), limit: 16384).data()
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        Set(object.keys).isSubset(of: ["schema", "lane", "sourceBytes", "repetitions", "sourceProfile", "geometry", "pairID"]) else {
        throw MatchedRefusal(message: "Unknown recipe schema fields.")
      }
      if let geometry = object["geometry"], !(geometry is NSNull) {
        guard let fields = geometry as? [String: Any],
          Set(fields.keys) == Set(["viewportWidth", "viewportHeight", "containerWidth", "lineFragmentPadding",
            "insetX", "insetY", "fontName", "fontSize", "lineSpacing", "drawsBackground"]) else {
          throw MatchedRefusal(message: "Unknown or incomplete matched geometry fields.")
        }
      }
      return try JSONDecoder().decode(MatchedRecipe.self, from: data)
    }.value
    try recipe.validate()
    let output = URL(fileURLWithPath: outputPath), source = output.appendingPathComponent("public-source.utf8")
    let oracle = try MatchedOracle(bytes: recipe.sourceBytes, profile: recipe.sourceProfile)
    let journal = try await Task.detached {
      try matchedRequire(!FileManager.default.fileExists(atPath: output.path), "Comparison output must be fresh.")
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
      return try MatchedJournal(url: output.appendingPathComponent("raw.ndjson"))
    }.value
    let sampler = Task.detached {
      do {
        while !Task.isCancelled {
          try await journal.tick(MatchedMemory.readSelf())
          try await Task.sleep(nanoseconds: 50000000)
        }
      } catch is CancellationError {} catch { await journal.noteMemoryFailure(error.localizedDescription) }
    }
    var failure: Error?, lane: MatchedLane?, workersJoined = false
    let resources = MatchedResources(); Self.retainedResources = resources
    do {
      let fixtureStart = matchedNow(), fixtureHash = try await Task.detached { try oracle.write(to: source) }.value
      struct Fixture: Encodable, Sendable {
        let kind = "source-fixture"
        let sha256: String
        let bytes: UInt64
        let generationNS: UInt64
        let pattern: String
        let publicTestKey = "32 bytes of 0xa7; public fixture only"
      }
      try await journal.metadata(Fixture(sha256: fixtureHash, bytes: recipe.sourceBytes,
        generationNS: matchedElapsed(fixtureStart), pattern: recipe.sourceProfile))
      _ = NSApplication.shared
      let prepare = matchedNow()
      lane = try await MatchedLane.create(recipe: recipe, oracle: oracle, journal: journal,
        scratch: output.appendingPathComponent("scratch"), source: source, resources: resources)
      Self.retainedFixture = lane
      struct Setup: Encodable, Sendable { let kind = "actual-product-or-component-setup"; let elapsedNS: UInt64 }
      try await journal.metadata(Setup(elapsedNS: matchedElapsed(prepare)))
      try await lane!.run()
      try await lane!.verifyRestoredSource(expectedSHA256: fixtureHash)
    } catch { failure = error }
    if let lane {
      do { try await lane.close(); workersJoined = true }
      catch { if failure == nil { failure = error } else { print("Matched public cleanup refusal retained: \(error)") } }
    } else {
      do { try await resources.closePartial(); workersJoined = true }
      catch { if failure == nil { failure = error } else { print("Matched public partial-setup cleanup refusal retained: \(error)") } }
    }
    sampler.cancel(); await sampler.value
    try await journal.finish(status: failure == nil ? "complete" : "incomplete", error: failure?.localizedDescription, workerJoined: workersJoined)
    // Preserve all public inputs, raw starts/partials/endings and encrypted
    // scratch on success too. Qualification owns exact test-process joins.
    if let failure { throw failure }
    XCTAssertEqual(lane?.completed, 210)
    XCTAssertTrue(workersJoined)
  }
}

#endif
