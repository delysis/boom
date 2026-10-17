import Foundation

/// The native player's acknowledged prefix. Production, scheduling and audible
/// delivery are different facts; only contiguous played-back acknowledgements
/// advance delivery. No PCM, voice, response history or device lives here.
struct SpeechPlaybackProgress {
  struct Ticket: Hashable, Sendable {
    fileprivate let epoch: UUID
    fileprivate let ordinal: UInt64
  }
  enum AdmissionError: Error, Equatable {
    case retired, invalidFrameCount, frameLimit, packetLimit, exhausted
  }
  private struct Packet {
    let end: Int
    let frames: Int
    var played = false
  }
  private let epoch = UUID()
  private let maximumFrames: Int
  private let maximumPackets: Int
  private var next: UInt64 = 0
  private var first: UInt64 = 0
  private var packets: [UInt64: Packet] = [:]
  private(set) var scheduledFrames = 0
  private(set) var pendingFrames = 0
  private(set) var deliveredFrames = 0
  private(set) var retired = false
  var isDrained: Bool { packets.isEmpty && pendingFrames == 0 }

  init(maximumFrames: Int = 16_000_000, maximumPackets: Int = 4096) {
    self.maximumFrames = max(0, maximumFrames)
    self.maximumPackets = max(0, maximumPackets)
  }

  /// Admission is all-or-nothing. A refused packet cannot advance any cursor.
  mutating func schedule(frames: Int) throws -> Ticket {
    guard !retired else { throw AdmissionError.retired }
    guard frames > 0 else { throw AdmissionError.invalidFrameCount }
    guard scheduledFrames <= maximumFrames, frames <= maximumFrames - scheduledFrames else {
      throw AdmissionError.frameLimit
    }
    guard packets.count < maximumPackets else { throw AdmissionError.packetLimit }
    guard next < UInt64.max else { throw AdmissionError.exhausted }
    let ticket = Ticket(epoch: epoch, ordinal: next)
    let end = scheduledFrames + frames
    packets[next] = Packet(end: end, frames: frames)
    next += 1; scheduledFrames = end; pendingFrames += frames
    return ticket
  }

  /// A duplicate, foreign or retired callback is inert. Main-actor callbacks may
  /// arrive out of order even when the audio device played buffers in order.
  /// A later acknowledgement never credits an earlier unacknowledged interval.
  @discardableResult mutating func played(_ ticket: Ticket) -> Bool {
    guard !retired, ticket.epoch == epoch,
      var packet = packets[ticket.ordinal], !packet.played else { return false }
    packet.played = true; packets[ticket.ordinal] = packet
    pendingFrames -= packet.frames
    while let head = packets[first], head.played {
      deliveredFrames = head.end
      packets.removeValue(forKey: first); first += 1
    }
    return true
  }

  /// Freeze the last witnessed prefix before unscheduling the device. Native
  /// callbacks caused by stop are not evidence that the caller heard the tail.
  mutating func retire() {
    retired = true; packets.removeAll(); pendingFrames = 0
  }
}
