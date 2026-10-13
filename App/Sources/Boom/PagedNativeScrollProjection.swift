import BoomCore
import Foundation

/// One read-only net replacement of the bounded physical island. Its source
/// remains an actual immutable revision; projected counters never change it.
struct PagedNativeScrollSnapshot: Sendable {
  let source: PagedTextWindow
  let replacement: Data
  let replacementUTF16: Int
  let removedSummary: PagedTextSummary
  let replacementSummary: PagedTextSummary
  let projectedSummary: PagedTextSummary
  let sessionID: UUID
  let arenaID: UUID
  let generation: UInt64
  var revision: PagedTextRevision { source.revision }

  init(source: PagedTextWindow, replacement: Data, replacementUTF16: Int,
    sessionID: UUID, arenaID: UUID, generation: UInt64) throws {
    try source.validate()
    guard source.text.utf8.count <= PagedWorkingWindow.hardBytes,
      replacement.count <= PagedWorkingWindow.hardBytes, replacementUTF16 >= 0,
      let text = String(data: replacement, encoding: .utf8), text.utf16.count == replacementUTF16 else {
      throw BoomError.invalid("Read-only native projection exceeds its exact scalar arena.")
    }
    self.source = source; self.replacement = replacement; self.replacementUTF16 = replacementUTF16
    self.sessionID = sessionID; self.arenaID = arenaID; self.generation = generation
    removedSummary = Self.summary(source.text); replacementSummary = Self.summary(text)
    projectedSummary = try Self.replace(source.revision.summary, removing: removedSummary, with: replacementSummary)
  }

  fileprivate static func summary(_ text: String) -> PagedTextSummary {
    PagedTextSummary(bytes: UInt64(text.utf8.count), utf16: UInt64(text.utf16.count),
      lfCount: text.utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) })
  }
  private static func replace(_ total: PagedTextSummary, removing old: PagedTextSummary,
    with next: PagedTextSummary) throws -> PagedTextSummary {
    func counter(_ total: UInt64, _ old: UInt64, _ next: UInt64) throws -> UInt64 {
      guard old <= total else { throw BoomError.invalid("Read-only overlay exceeds its immutable source.") }
      let sum = (total - old).addingReportingOverflow(next)
      guard !sum.overflow else { throw BoomError.budget("Read-only projected coordinate overflowed.") }
      return sum.partialValue
    }
    let value = try PagedTextSummary(bytes: counter(total.bytes, old.bytes, next.bytes),
      utf16: counter(total.utf16, old.utf16, next.utf16), lfCount: counter(total.lfCount, old.lfCount, next.lfCount))
    try value.validate(); return value
  }
}

/// Copied display text has no root publication or local-edit authority. No
/// source lease survives the completed read just to display these characters.
struct PagedNativeScrollProjection: Sendable {
  let snapshot: PagedNativeScrollSnapshot
  let windowID: UUID
  let byteStart: UInt64
  let utf16Start: UInt64
  let lfStart: UInt64
  let text: String
  var revision: PagedTextRevision { snapshot.revision }
  var projectedSummary: PagedTextSummary { snapshot.projectedSummary }

  func validate() throws {
    let local = PagedNativeScrollSnapshot.summary(text)
    func end(_ start: UInt64, _ amount: UInt64, _ limit: UInt64) throws {
      let value = start.addingReportingOverflow(amount)
      guard !value.overflow, value.partialValue <= limit else {
        throw BoomError.invalid("Read-only scroll text exceeds its projected source.")
      }
    }
    guard text.utf8.count <= PagedWorkingWindow.targetBytes else {
      throw BoomError.budget("Read-only scroll projection exceeds its display budget.")
    }
    try end(byteStart, local.bytes, projectedSummary.bytes)
    try end(utf16Start, local.utf16, projectedSummary.utf16)
    try end(lfStart, local.lfCount, projectedSummary.lfCount)
  }

  func validateLocalPosition(_ offset: Int) throws {
    guard offset >= 0 else { throw BoomError.invalid("Negative display selection.") }
    var units = 0
    for scalar in text.unicodeScalars {
      if units == offset { return }
      units += scalar.value > 0xffff ? 2 : 1
      if units > offset { throw BoomError.invalid("Display selection splits a Unicode scalar.") }
    }
    guard units == offset else { throw BoomError.invalid("Display selection exceeds its copied text.") }
  }

  /// The closure reads only the captured immutable root. At most two bounded
  /// source windows surround the net island replacement, independent of how
  /// many accepted/in-flight primitives produced that replacement.
  static func compose(_ snapshot: PagedNativeScrollSnapshot, utf16Anchor: UInt64,
    maximumBytes: Int, readSource: (UInt64, Int) throws -> PagedTextWindow) throws -> Self {
    guard (4...PagedWorkingWindow.targetBytes).contains(maximumBytes) else {
      throw BoomError.budget("Scroll display has no bounded scalar budget.")
    }
    let source = snapshot.source
    let oldByteEnd = source.byteStart + snapshot.removedSummary.bytes
    let oldUTF16End = source.utf16Start + snapshot.removedSummary.utf16
    let newUTF16End = source.utf16Start + snapshot.replacementSummary.utf16
    let anchor = min(utf16Anchor, snapshot.projectedSummary.utf16)
    var output = Data(); output.reserveCapacity(maximumBytes)
    var startBytes: UInt64, startUTF16: UInt64, startLF: UInt64

    func read(_ offset: UInt64, _ budget: Int) throws -> PagedTextWindow {
      let window = try readSource(offset, max(4, budget)); try window.validate()
      guard window.revision == snapshot.revision, window.utf16Start <= offset,
        offset - window.utf16Start <= 1, window.text.utf8.count <= max(4, budget) else {
        throw BoomError.invalid("Immutable scroll reader changed its captured source or scalar anchor.")
      }
      return window
    }
    func append(_ bytes: Data) {
      var count = min(maximumBytes - output.count, bytes.count)
      // A byte immediately after the slice must begin a scalar (or be EOF).
      while count > 0, count < bytes.count, bytes[count] & 0xc0 == 0x80 { count -= 1 }
      output.append(bytes.prefix(count))
    }
    func mapped(_ value: UInt64, _ old: UInt64, _ new: UInt64) throws -> UInt64 {
      guard value >= old else { throw BoomError.invalid("Source suffix precedes the removed island.") }
      let result = (value - old).addingReportingOverflow(new)
      guard !result.overflow else { throw BoomError.budget("Projected scroll offset overflowed.") }
      return result.partialValue
    }

    if anchor < source.utf16Start {
      let window = try read(anchor, maximumBytes), bytes = Data(window.text.utf8)
      startBytes = window.byteStart; startUTF16 = window.utf16Start; startLF = window.lfStart
      guard window.byteStart <= source.byteStart else { throw BoomError.invalid("Source prefix moved past its island.") }
      let gap = source.byteStart - window.byteStart
      if gap > UInt64(bytes.count) {
        append(bytes)
        return try finish(snapshot, output, startBytes, startUTF16, startLF)
      }
      append(Data(bytes.prefix(Int(gap))))
      append(snapshot.replacement)
      if output.count < maximumBytes,
        UInt64(output.count) == gap + snapshot.replacementSummary.bytes,
        oldUTF16End < snapshot.revision.summary.utf16 {
        append(Data(try read(oldUTF16End, maximumBytes - output.count).text.utf8))
      }
    } else if anchor < newUTF16End {
      guard let replacement = String(data: snapshot.replacement, encoding: .utf8) else {
        throw BoomError.invalid("Native overlay lost its scalar encoding.")
      }
      var localBytes = 0, localUTF16: UInt64 = 0, localLF: UInt64 = 0
      let requested = anchor - source.utf16Start
      for scalar in replacement.unicodeScalars {
        let units: UInt64 = scalar.value > 0xffff ? 2 : 1
        if localUTF16 + units > requested { break }
        localUTF16 += units; localBytes += (scalar.value < 0x80 ? 1 : scalar.value < 0x800 ? 2 : scalar.value < 0x10000 ? 3 : 4)
        if scalar.value == 10 { localLF += 1 }
      }
      startBytes = source.byteStart + UInt64(localBytes)
      startUTF16 = source.utf16Start + localUTF16; startLF = source.lfStart + localLF
      let tail = snapshot.replacement.subdata(in: localBytes..<snapshot.replacement.count)
      append(tail)
      if output.count == tail.count, output.count < maximumBytes,
        oldUTF16End < snapshot.revision.summary.utf16 {
        append(Data(try read(oldUTF16End, maximumBytes - output.count).text.utf8))
      }
    } else {
      let sourceAnchor = oldUTF16End + (anchor - newUTF16End)
      let window = try read(sourceAnchor, maximumBytes)
      guard window.byteStart >= oldByteEnd, window.utf16Start >= oldUTF16End else {
        throw BoomError.invalid("Source suffix overlaps the removed island.")
      }
      startBytes = try mapped(window.byteStart, snapshot.removedSummary.bytes, snapshot.replacementSummary.bytes)
      startUTF16 = try mapped(window.utf16Start, snapshot.removedSummary.utf16, snapshot.replacementSummary.utf16)
      startLF = try mapped(window.lfStart, snapshot.removedSummary.lfCount, snapshot.replacementSummary.lfCount)
      append(Data(window.text.utf8))
    }
    return try finish(snapshot, output, startBytes, startUTF16, startLF)
  }

  private static func finish(_ snapshot: PagedNativeScrollSnapshot, _ bytes: Data,
    _ byteStart: UInt64, _ utf16Start: UInt64, _ lfStart: UInt64) throws -> Self {
    guard let text = String(data: bytes, encoding: .utf8) else { throw BoomError.invalid("Scroll display split a scalar.") }
    let result = Self(snapshot: snapshot, windowID: UUID(), byteStart: byteStart,
      utf16Start: utf16Start, lfStart: lfStart, text: text)
    try result.validate(); return result
  }
}
