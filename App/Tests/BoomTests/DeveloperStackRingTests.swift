#if BLOOM_DEVELOPER_STACK_DIAGNOSTICS
import Testing
import Synchronization
@testable import Boom

@Suite(.serialized)
struct DeveloperStackRingTests {
  private func append(_ count: Int, to ring: DeveloperStackDiagnostics.Ring) {
    for _ in 0..<count {
      let sequence = ring.nextSequence()
      let token = DeveloperStackDiagnostics.Token(sequence: sequence, tid: ring.tid, stage: 1, event: 0)
      ring.append(sequence: sequence, correlation: token, kind: .event, value: 0)
    }
  }

  @Test func uncommittedPrefixSurvivesRepeatedPeeksAndFinalDiscardCountsOnce() {
    let ring = DeveloperStackDiagnostics.Ring(tid: 1, role: .main)
    var buffer = [DeveloperStackWire.Phase](repeating: .init(), count: DeveloperStackWire.phasesPerMessage)
    append(3, to: ring)
    for _ in 0..<4 {
      let count = buffer.withUnsafeMutableBufferPointer { ring.peek(into: $0) }
      #expect(count == 3)
      #expect(buffer.prefix(count).map(\.sequence) == [1, 2, 3])
    }
    ring.commit(2)
    let count = buffer.withUnsafeMutableBufferPointer { ring.peek(into: $0) }
    #expect(count == 1 && buffer[0].sequence == 3)
    #expect(ring.ringFull.load(ordering: .relaxed) == 0)
    #expect(ring.discardPending() == 1)
    #expect(ring.discardPending() == 0)
    #expect(buffer.withUnsafeMutableBufferPointer { ring.peek(into: $0) } == 0)
  }

  @Test func wrappedQueueRetainsExactOrderAndReportsOnlyActualProducerOverflow() {
    let ring = DeveloperStackDiagnostics.Ring(tid: 1, role: .main)
    let width = DeveloperStackWire.phasesPerMessage, capacity = DeveloperStackWire.ringRecords
    var buffer = [DeveloperStackWire.Phase](repeating: .init(), count: width)
    append(capacity, to: ring)
    append(1, to: ring) // The ring is full; this sequence is genuinely lost.
    #expect(ring.ringFull.load(ordering: .relaxed) == 1)
    let first = buffer.withUnsafeMutableBufferPointer { ring.peek(into: $0) }
    #expect(first == width)
    #expect(buffer.map(\.sequence) == (1...width).map(UInt64.init))
    ring.commit(first)
    append(width, to: ring) // Actual slot reuse across the physical wrap.
    var observed: [UInt64] = []
    for _ in 0..<(capacity / width) {
      let count = buffer.withUnsafeMutableBufferPointer { ring.peek(into: $0) }
      #expect(count == width)
      observed.append(contentsOf: buffer.prefix(count).map(\.sequence))
      ring.commit(count)
    }
    let expected = (width + 1...capacity).map(UInt64.init)
      + (capacity + 2...capacity + width + 1).map(UInt64.init)
    #expect(observed == expected)
    #expect(ring.ringFull.load(ordering: .relaxed) == 1)
    #expect(ring.discardPending() == 0)
  }
}
#endif
