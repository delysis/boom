import AppKit
import BoomCore
import CoreFoundation

/// A native input payload is copied as values, never as arbitrary attributed
/// objects. In particular, mutable data, attachments and pattern colors cannot
/// hide an uncharged backing allocation behind a one-character marked string.
@MainActor struct PagedNativeContextPayload {
  static let markedAttributes: [NSAttributedString.Key] = [
    .markedClauseSegment, .underlineStyle, .underlineColor,
    .foregroundColor, .backgroundColor, .font, .baselineOffset, .kern,
    .writingDirection, .verticalGlyphForm, .ligature,
  ]
  @MainActor private enum Value {
    case integer(Int64), real(Double), color(Double, Double, Double, Double)
    case font(String, Double), directions([Int64])

    var charge: Int {
      switch self {
      case .font(let name, _): return 4_096 + name.utf8.count
      case .directions(let values): return 512 + values.count * 32
      default: return 512
      }
    }
    func materialize() throws -> Any {
      switch self {
      case .integer(let value): return NSNumber(value: value)
      case .real(let value): return NSNumber(value: value)
      case .color(let r, let g, let b, let a):
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
      case .font(let name, let size):
        guard let font = NSFont(name: name, size: size) else {
          throw BoomError.unavailable("The native input font is no longer available.")
        }
        return font
      case .directions(let values): return values.map { NSNumber(value: $0) }
      }
    }
  }
  private struct Run {
    let range: NSRange
    let attributes: [NSAttributedString.Key: Value]
  }
  let text: String
  let chargedBytes: Int
  private let runs: [Run]

  init(_ original: Any) throws {
    let attributed = original as? NSAttributedString
    if let attributed {
      // Read the extent before bridging/copying the string or attributes.
      guard attributed.length <= PagedCapturedEditInput.maximumInputBytes else {
        throw BoomError.budget("Native attributed input exceeds its text bound.")
      }
      text = attributed.string
    } else if let string = original as? String { text = string }
    else { throw BoomError.invalid("Native text input is neither text nor attributed text.") }
    guard text.utf8.count <= PagedCapturedEditInput.maximumInputBytes else {
      throw BoomError.budget("Native input exceeds its UTF8 bound.")
    }
    var charge = text.utf8.count + 512
    var captured: [Run] = []
    if let attributed, attributed.length > 0 {
      let cfText = attributed as CFAttributedString
      var at = 0, inspectedRuns = 0
      while at < attributed.length {
        guard inspectedRuns < 64 else { throw BoomError.budget("Native input has too many attribute runs.") }
        inspectedRuns += 1
        var extent = CFRange()
        let raw = CFAttributedStringGetAttributes(cfText, at, &extent)!
        // Count borrowed CF metadata before Foundation could bridge an
        // unbounded attribute dictionary into an owned Swift Dictionary.
        guard CFDictionaryGetCount(raw) <= Self.markedAttributes.count,
          extent.location >= 0, extent.location <= at, extent.length > 0,
          extent.length <= attributed.length - extent.location,
          extent.location + extent.length > at else {
          throw BoomError.budget("Native input has unbounded or invalid attributes.")
        }
        var values: [NSAttributedString.Key: Value] = [:]
        var known = 0
        for key in Self.markedAttributes {
          let object = key.rawValue as NSString
          guard let pointer = CFDictionaryGetValue(raw, Unmanaged.passUnretained(object).toOpaque()) else { continue }
          let value = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
          let capturedValue = try Self.capture(value, for: key)
          let next = charge.addingReportingOverflow(capturedValue.charge)
          guard !next.overflow, next.partialValue <= PagedNativeUndoOwner.maximumRawKeyBytes else {
            throw BoomError.budget("Native input attributes exceed the bounded input custody.")
          }
          charge = next.partialValue; known += 1; values[key] = capturedValue
        }
        guard known == CFDictionaryGetCount(raw) else {
          throw BoomError.invalid("Native input has an unsupported marked-text attribute.")
        }
        let runEnd = extent.location + extent.length
        if !values.isEmpty {
          let stringBacking = captured.isEmpty ? attributed.length * 2 + 512 : 0
          let next = charge.addingReportingOverflow(1_024 + stringBacking)
          guard !next.overflow, next.partialValue <= PagedNativeUndoOwner.maximumRawKeyBytes else {
            throw BoomError.budget("Native input run storage exceeds the bounded input custody.")
          }
          charge = next.partialValue
          captured.append(Run(range: NSRange(location: at, length: runEnd - at), attributes: values))
        }
        at = runEnd
      }
    }
    chargedBytes = charge; runs = captured
  }

  /// The caller first checks the SAME owner's remaining shared charge. This
  /// allocation retains only the already bounded immutable scalar values.
  func materialize() throws -> Any {
    guard !runs.isEmpty else { return text }
    let result = NSMutableAttributedString(string: text)
    for run in runs {
      let values = try run.attributes.mapValues { try $0.materialize() }
      result.setAttributes(values, range: run.range)
    }
    return NSAttributedString(attributedString: result)
  }

  private static func integer(_ value: AnyObject) throws -> Int64 {
    guard let number = value as? NSNumber,
      number.doubleValue.isFinite, number.doubleValue == Double(number.int64Value) else {
      throw BoomError.invalid("Native marked-text integer is not a bounded scalar.")
    }
    return number.int64Value
  }
  private static func capture(_ value: AnyObject, for key: NSAttributedString.Key) throws -> Value {
    switch key {
    case .markedClauseSegment, .underlineStyle, .verticalGlyphForm, .ligature:
      return .integer(try integer(value))
    case .kern, .baselineOffset:
      guard let number = value as? NSNumber, number.doubleValue.isFinite,
        abs(number.doubleValue) <= 4_096 else {
        throw BoomError.invalid("Native marked-text spacing is not a bounded scalar.")
      }
      return .real(number.doubleValue)
    case .underlineColor, .foregroundColor, .backgroundColor:
      guard let input = value as? NSColor, let color = input.usingColorSpace(.sRGB) else {
        throw BoomError.invalid("Native marked-text color has no bounded RGB value.")
      }
      let parts = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
      guard parts.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
        throw BoomError.invalid("Native marked-text color is not finite RGB.")
      }
      return .color(parts[0], parts[1], parts[2], parts[3])
    case .font:
      guard let font = value as? NSFont, font.fontName.utf8.count <= 256,
        font.pointSize.isFinite, (0...4_096).contains(font.pointSize), font.pointSize > 0 else {
        throw BoomError.invalid("Native marked-text font is not bounded.")
      }
      return .font(font.fontName, font.pointSize)
    case .writingDirection:
      guard let directions = value as? NSArray, directions.count <= 16 else {
        throw BoomError.invalid("Native marked-text directions exceed their bounded values.")
      }
      return .directions(try directions.map { try integer($0 as AnyObject) })
    default: throw BoomError.invalid("Unsupported native marked-text attribute.")
    }
  }
}
