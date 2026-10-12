import Crypto
import Foundation

/// Portable content identity through Swift Crypto and system CryptoKit on macOS.
public enum Digest {
  private static let hexDigits = Array("0123456789abcdef".utf8)

  public static func sha256(_ string: String) -> String {
    if let digest = string.utf8.withContiguousStorageIfAvailable({ bytes in
      var hasher = SHA256()
      hasher.update(bufferPointer: UnsafeRawBufferPointer(bytes))
      return hexadecimal(hasher.finalize())
    }) {
      return digest
    }
    // A foreign String may lack contiguous UTF-8 storage; copy only this explicit input.
    return sha256(Data(string.utf8))
  }

  public static func sha256(_ data: Data) -> String {
    hexadecimal(SHA256.hash(data: data))
  }

  private static func hexadecimal(_ digest: SHA256.Digest) -> String {
    var bytes = [UInt8](repeating: 0, count: SHA256.byteCount * 2)
    digest.withUnsafeBytes { digestBytes in
      for (index, byte) in digestBytes.enumerated() {
        bytes[index * 2] = hexDigits[Int(byte >> 4)]
        bytes[index * 2 + 1] = hexDigits[Int(byte & 0x0f)]
      }
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// Local Swift JSON identity encoding: sorted keys, unescaped slashes and
  /// otherwise JSONEncoder defaults. This is not a cross-language canonical
  /// JSON format; persisted identities must retain these encoding semantics.
  public static func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
  public static func identity<T: Encodable>(_ value: T) throws -> String {
    sha256(try canonical(value))
  }
}
