import AppKit
import QuartzCore
import XCTest
@testable import Boom

final class NativeTextDrawingTests: XCTestCase {
  private final class MediaRenderer: NSObject, CALayerDelegate {}

  @MainActor func testLateContentDrawingSettingAndRetirement() {
    let backing = CALayer()
    let policy = NativeTextDrawing(backing: backing)
    withExtendedLifetime(policy) {
      let text = CALayer()
      backing.addSublayer(text)
      // AppKit sets this after inserting its text-content layer.
      text.drawsAsynchronously = true
      XCTAssertFalse(text.drawsAsynchronously)
      text.removeFromSuperlayer()
      text.drawsAsynchronously = true
      XCTAssertTrue(text.drawsAsynchronously, "Retired layers must leave the policy's custody.")
    }
  }

  @MainActor func testDelegatedMediaLayerAndPixelFormatRemainOwnedByTheirRenderer() {
    let backing = CALayer(), text = CALayer(), media = CALayer()
    let mediaDelegate = MediaRenderer()
    media.delegate = mediaDelegate
    text.contentsFormat = .RGBA16Float
    text.drawsAsynchronously = true
    media.contentsFormat = .RGBA16Float
    media.drawsAsynchronously = true
    let child = CALayer()
    child.drawsAsynchronously = true
    media.addSublayer(child)
    backing.addSublayer(text); backing.addSublayer(media)
    let policy = NativeTextDrawing(backing: backing)
    withExtendedLifetime((policy, mediaDelegate)) {
      XCTAssertFalse(text.drawsAsynchronously)
      XCTAssertEqual(text.contentsFormat, .RGBA16Float)
      XCTAssertTrue(media.drawsAsynchronously)
      XCTAssertTrue(child.drawsAsynchronously)
      XCTAssertEqual(media.contentsFormat, .RGBA16Float)
    }
  }

  @MainActor func testPolicyReleaseStopsObservingSurvivingLayer() {
    let backing = CALayer(), text = CALayer()
    backing.addSublayer(text)
    var policy: NativeTextDrawing? = NativeTextDrawing(backing: backing)
    weak var released = policy
    withExtendedLifetime(policy) {
      text.drawsAsynchronously = true
      XCTAssertFalse(text.drawsAsynchronously)
    }
    policy = nil
    XCTAssertNil(released)
    text.drawsAsynchronously = true
    XCTAssertTrue(text.drawsAsynchronously)
  }
}
