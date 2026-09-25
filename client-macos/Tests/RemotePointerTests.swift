import AppKit
import XCTest

@testable import VibeRDP

@MainActor
final class RemotePointerTests: XCTestCase {
    /// The core hands over B, G, R, A with straight alpha: blue stays blue, and a half transparent red is not darkened
    func testPixelsKeepTheirColors() throws {
        let image = PointerImage(
            width: 2, height: 1, hotspotX: 0, hotspotY: 0, pixels: Data([0xFF, 0, 0, 0xFF, 0, 0, 0xFF, 0x80]))
        let cursor = try XCTUnwrap(image.cursor(pointsPerPixel: 1))
        let drawn = try XCTUnwrap(cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil))

        // Premultiplied RGBA, the way a screen composes it
        var pixels = [UInt8](repeating: 0, count: 8)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(drawn, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        XCTAssertEqual(Array(pixels[0..<4]), [0, 0, 0xFF, 0xFF])
        XCTAssertEqual(Int(pixels[4]), 0x80, accuracy: 1)
        XCTAssertEqual(Array(pixels[5..<7]), [0, 0])
        XCTAssertEqual(pixels[7], 0x80)
    }

    /// The cursor is as large as the desktop is drawn, and its hot spot moves with it
    func testCursorScalesWithTheDesktop() throws {
        let image = PointerImage(
            width: 32, height: 32, hotspotX: 10, hotspotY: 4, pixels: Data(count: 32 * 32 * 4))
        let cursor = try XCTUnwrap(image.cursor(pointsPerPixel: 1.5))
        XCTAssertEqual(cursor.image.size, NSSize(width: 48, height: 48))
        XCTAssertEqual(cursor.hotSpot, NSPoint(x: 15, y: 6))
    }

    func testHotspotPastTheEdgeStaysInside() throws {
        let image = PointerImage(
            width: 32, height: 32, hotspotX: 40, hotspotY: 40, pixels: Data(count: 32 * 32 * 4))
        let cursor = try XCTUnwrap(image.cursor(pointsPerPixel: 1))
        XCTAssertEqual(cursor.hotSpot, NSPoint(x: 31, y: 31))
    }

    func testImageOfTheWrongSizeHasNoCursor() {
        let image = PointerImage(width: 2, height: 2, hotspotX: 0, hotspotY: 0, pixels: Data(count: 4))
        XCTAssertNil(image.cursor(pointsPerPixel: 1))
    }
}
