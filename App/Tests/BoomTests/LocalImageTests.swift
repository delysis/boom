import AppKit
import XCTest
@testable import Boom

final class LocalImageTests: XCTestCase {
  func testImageBytesNeedNoExtractedText() throws {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.setColor(.red, atX: 0, y: 0)
    let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    XCTAssertTrue(LocalImage.canDecode(image))
    XCTAssertEqual(try LocalImage.decode(image).extent.width, 4)
    XCTAssertFalse(LocalImage.canDecode(Data("not an image".utf8)))
  }
}
