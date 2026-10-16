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
  static func decode(_ data: Data) throws -> (samples: [Float], rate: Int) {
    guard data.count > 44, data.count <= 64_000_044,
      data.prefix(4) == Data("RIFF".utf8), data[8..<16] == Data("WAVEfmt ".utf8),
      data[36..<40] == Data("data".utf8) else { throw BoomError.invalid("Not a retained Blessenger waveform.") }
    func u32(_ start: Int) -> UInt32 { data[start..<start+4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) } }
    guard u32(4) == data.count - 8, u32(16) == 16, data[20] == 3, data[21] == 0,
      data[22] == 1, data[23] == 0, data[32] == 4, data[33] == 0, data[34] == 32, data[35] == 0,
      u32(40) == data.count - 44, (data.count - 44) % 4 == 0,
      (8000...96000).contains(Int(u32(24))), u32(28) == u32(24) * 4 else { throw BoomError.invalid("Retained waveform geometry changed.") }
    let samples = stride(from: 44, to: data.count, by: 4).map { Float(bitPattern: u32($0)) }
    guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1.01 }) else { throw BoomError.invalid("Invalid retained PCM.") }
    return (samples, Int(u32(24)))
  }
}
