import BoomCore
import Foundation

final class BlessengerTrace: @unchecked Sendable {
  struct Event: Codable, Sendable { let name: String; let uptime: Double }
  struct Record: Codable, Sendable {
    let operation: UUID; let events: [Event]; let incomplete: Bool
    let source: String; let runtime: String
  }
  let operation: UUID
  private let lock = NSLock()
  private var events: [Event] = []
  private var overflow = false
  init(operation: UUID = UUID()) { self.operation = operation }
  func record(_ name: String, at time: Double = ProcessInfo.processInfo.systemUptime) {
    lock.lock(); defer { lock.unlock() }
    guard time.isFinite, time >= 0, !name.isEmpty, name.utf8.count <= 96, events.count < 512 else { overflow = true; return }
    events.append(Event(name: name, uptime: time))
  }
  func once(_ name: String, at time: Double = ProcessInfo.processInfo.systemUptime) {
    lock.lock(); defer { lock.unlock() }
    guard !events.contains(where: { $0.name == name }) else { return }
    guard time.isFinite, time >= 0, !name.isEmpty, name.utf8.count <= 96, events.count < 512 else { overflow = true; return }
    events.append(Event(name: name, uptime: time))
  }
  func snapshot() -> Record {
    lock.lock(); defer { lock.unlock() }
    return Record(operation: operation, events: events, incomplete: overflow,
      source: Bundle.main.object(forInfoDictionaryKey: "BoomSourceSHA256") as? String ?? "unpackaged",
      runtime: ModelPacks.runtimeRevision)
  }
}

/// A byte-exact Float32 waveform for authored and generated PCM. Saving this
/// explicit audio record never uses a plaintext temporary file.
enum BlessengerWave {
  static func encode(_ samples: [Float], rate: Int) throws -> Data {
    guard (8000...96000).contains(rate), !samples.isEmpty, samples.count <= 16_000_000,
      samples.allSatisfy({ $0.isFinite && abs($0) <= 1.01 }) else { throw BoomError.invalid("Invalid private waveform.") }
    var data = Data(capacity: 44 + samples.count * 4)
    func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
    let size = UInt32(samples.count * 4)
    data.append(contentsOf: "RIFF".utf8); append(size + 36); data.append(contentsOf: "WAVEfmt ".utf8)
    append(UInt32(16)); append(UInt16(3)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate * 4))
    append(UInt16(4)); append(UInt16(32)); data.append(contentsOf: "data".utf8); append(size)
    for value in samples { append(value.bitPattern) }
    _ = try ProductCore.admitMedia(data); return data
  }
  static func geometry(_ data: Data) throws -> (samples: Int, rate: Int) {
    guard data.count > 44, data.count <= 64_000_044 else { throw BoomError.invalid("Not a retained Blessenger waveform.") }
    // Data subsequences need not start at index zero. Raw byte offsets are
    // relative to this value's own storage and cannot index a preceding slice.
    return try data.withUnsafeBytes { raw in
      func u32(_ start: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: start, as: UInt32.self)) }
      guard raw[0..<4].elementsEqual("RIFF".utf8), raw[8..<16].elementsEqual("WAVEfmt ".utf8),
        raw[36..<40].elementsEqual("data".utf8) else { throw BoomError.invalid("Not a retained Blessenger waveform.") }
      guard u32(4) == data.count - 8, u32(16) == 16, raw[20] == 3, raw[21] == 0,
        raw[22] == 1, raw[23] == 0, raw[32] == 4, raw[33] == 0, raw[34] == 32, raw[35] == 0,
        u32(40) == data.count - 44, (data.count - 44) % 4 == 0,
        (8000...96000).contains(Int(u32(24))), u32(28) == u32(24) * 4 else { throw BoomError.invalid("Retained waveform geometry changed.") }
      return ((data.count - 44) / 4, Int(u32(24)))
    }
  }
  static func decode(_ data: Data, maximumSamples: Int = 16_000_000) throws -> (samples: [Float], rate: Int) {
    let shape = try geometry(data)
    guard maximumSamples >= 0 else { throw BoomError.invalid("Invalid retained waveform reservation.") }
    guard shape.samples <= maximumSamples else { throw BoomError.budget("Selected decoded audio exceeds its memory reservation; the original is unchanged.") }
    let samples = data.withUnsafeBytes { raw in
      (0..<shape.samples).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 44 + $0 * 4, as: UInt32.self))) }
    }
    guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1.01 }) else { throw BoomError.invalid("Invalid retained PCM.") }
    return (samples, shape.rate)
  }
}
