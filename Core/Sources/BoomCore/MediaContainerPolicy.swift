import Foundation

public enum MediaContainerPolicy {
  /// Reject external QuickTime/ISO-BMFF data references before AVFoundation sees
  /// the bytes. Only a local, self-contained MP4 is admitted; playlists are not.
  public static func selfContainedMP4(_ data: Data) throws -> Bool {
    let data = Data(data)  // normalize a Data slice's indices before offset arithmetic
    guard data.count <= 67_108_864 else { throw BoomError.budget("MP4 inspection exceeds 64 MiB.") }
    guard data.count >= 12, String(data: data.subdata(in: 4..<8), encoding: .ascii) == "ftyp" else {
      return false
    }
    var atoms = 0
    var references = 0
    func u32(_ n: Int) -> UInt64 { data[n..<n + 4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
    func scan(_ start: Int, _ end: Int, _ depth: Int) throws {
      guard depth <= 12 else { throw BoomError.budget("MP4 atom nesting too deep.") }
      var offset = start
      while offset < end {
        atoms += 1
        guard atoms <= 50_000, offset <= end - 8 else {
          throw BoomError.invalid("Malformed MP4 atom table.")
        }
        let short = u32(offset)
        let kind = String(data: data.subdata(in: offset + 4..<offset + 8), encoding: .ascii) ?? ""
        var header = 8
        var size = short
        if short == 1 {
          guard offset <= end - 16 else { throw BoomError.invalid("Truncated extended MP4 atom.") }
          header = 16
          size = (u32(offset + 8) << 32) | u32(offset + 12)
        }
        if short == 0 { size = UInt64(end - offset) }
        guard size >= UInt64(header), size <= UInt64(end - offset) else {
          throw BoomError.invalid("MP4 atom exceeds its containing bytes.")
        }
        let finish = offset + Int(size)
        let payload = offset + header
        if kind == "dref" {
          guard payload <= finish - 8 else {
            throw BoomError.invalid("Truncated MP4 data references.")
          }
          let count = u32(payload + 4)
          guard count > 0, count <= 256 else {
            throw BoomError.invalid("Invalid MP4 data-reference count.")
          }
          var entry = payload + 8
          for _ in 0..<Int(count) {
            guard entry <= finish - 12 else { throw BoomError.invalid("Truncated MP4 reference.") }
            let size = u32(entry)
            let type = String(data: data.subdata(in: entry + 4..<entry + 8), encoding: .ascii)
            guard size == 12, type == "url ", u32(entry + 8) == 1 else {
              throw BoomError.denied("External MP4 references are forbidden.")
            }
            entry += 12
            references += 1
          }
          guard entry == finish else {
            throw BoomError.invalid("Unexpected MP4 reference payload.")
          }
        } else if ["moov", "trak", "mdia", "minf", "dinf", "stbl", "edts", "mvex"].contains(kind) {
          try scan(payload, finish, depth + 1)
        }
        offset = finish
      }
    }
    try scan(0, data.count, 0)
    return references > 0
  }
}
