import Foundation

/// Hardware advice is separate from runtime admission. A recommended model is
/// usable only after its exact target and matching drafter have been verified
/// and the local backend reports that it can load both.
public enum GemmaSize: String, CaseIterable, Sendable {
  case e2b = "E2B"
  case e4b = "E4B"
  case b12 = "12B"
  case b26a4b = "26B-A4B"
  case b31 = "31B"

  public var nominalBillions: Int {
    switch self {
    case .e2b: 2
    case .e4b: 4
    case .b12: 12
    case .b26a4b: 26
    case .b31: 31
    }
  }
  public var architectureContext: Int {
    switch self {
    case .e2b, .e4b: 131_072
    case .b12, .b26a4b, .b31: 262_144
    }
  }
  public var qatRepository: String { "google/gemma-4-\(rawValue)-it-qat-q4_0-gguf" }
  public var mobileRepository: String? {
    switch self {
    case .e2b, .e4b: "google/gemma-4-\(rawValue)-it-qat-mobile-transformers"
    default: nil
    }
  }
  public var qatAssistantRepository: String {
    "google/gemma-4-\(rawValue)-it-qat-q4_0-unquantized-assistant"
  }
}

public enum ModelMemoryPolicy {
  /// Decimal GB matches the advertised parameter counts. E2B/E4B use their
  /// mobile QAT footprint rather than pretending all PLE tables were offloaded.
  /// The 31B choice on a 32 GB Mac follows the product rule; the Q4 payload is
  /// about 15.5 GB, while loader overhead makes its actual footprint larger.
  public static func recommendedSize(physicalBytes: UInt64) -> GemmaSize? {
    let ramGB = Double(physicalBytes) / 1_000_000_000
    for size in GemmaSize.allCases.reversed() where Double(size.nominalBillions) < ramGB {
      if size == .e2b || size == .e4b {
        let mobileGB = size == .e2b ? 1.1 : 2.5
        if mobileGB < ramGB / 2 { return size }
      } else if Double(size.nominalBillions) * 0.5 < ramGB / 2 {
        return size
      }
    }
    return nil
  }

  /// The loader supplies measured resident bytes and KV bytes per token. Use
  /// the device's recommended working set, reserve ten percent for concurrent
  /// allocations, then honor the model's architectural limit. Zero means this
  /// model cannot safely open a context on this device.
  public static func maximumContext(
    architectureLimit: Int, workingSetBytes: UInt64, residentBytes: UInt64,
    kvBytesPerToken: UInt64
  ) -> Int {
    guard architectureLimit > 0, kvBytesPerToken > 0 else { return 0 }
    let budget = workingSetBytes / 10 * 9
    guard residentBytes < budget else { return 0 }
    let tokens = (budget - residentBytes) / kvBytesPerToken
    return min(architectureLimit, Int(clamping: tokens))
  }
}
