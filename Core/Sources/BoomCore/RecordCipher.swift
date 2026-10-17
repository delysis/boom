import Crypto
import Foundation

/// A record's kind and stable ID are authenticated, not inferred from its path.
/// There is no plaintext fallback. Key management belongs to the native owner.
public struct RecordCipher: Sendable {
  public static let overhead = 36 // eight-byte format marker + 12-byte nonce + 16-byte tag
  private static let marker = Data("BLSSENC1".utf8)
  private let key: SymmetricKey

  public init(key: Data) throws {
    guard key.count == 32 else { throw BoomError.invalid("Private storage requires a 256-bit key.") }
    self.key = SymmetricKey(data: key)
  }
  /// Disposable state uses an unpersisted key, so a spill file is not a backup.
  public static func ephemeral() -> Self { Self(key: SymmetricKey(size: .bits256)) }
  private init(key: SymmetricKey) { self.key = key }

  public func seal(_ bytes: Data, binding: String) throws -> Data {
    guard !binding.isEmpty, binding.utf8.count <= 1024 else { throw BoomError.invalid("Invalid private record identity.") }
    let box = try AES.GCM.seal(bytes, using: key,
      authenticating: Self.marker + Data(binding.utf8))
    guard let combined = box.combined else { throw BoomError.invalid("Private record could not be sealed.") }
    return Self.marker + combined
  }
  public func open(_ bytes: Data, binding: String, limit: Int) throws -> Data {
    guard limit >= 0, bytes.count >= Self.overhead,
      bytes.count - Self.overhead <= limit, bytes.starts(with: Self.marker),
      !binding.isEmpty, binding.utf8.count <= 1024 else {
      throw BoomError.invalid("Unknown or oversized encrypted record. Original bytes were retained.")
    }
    let sealed = try AES.GCM.SealedBox(combined: bytes.dropFirst(Self.marker.count))
    return try AES.GCM.open(sealed, using: key,
      authenticating: Self.marker + Data(binding.utf8))
  }
}
