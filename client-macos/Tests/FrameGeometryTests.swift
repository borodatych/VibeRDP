import CoreGraphics
import XCTest

@testable import VibeRDP

final class FrameGeometryTests: XCTestCase {
    func testSameSizeIsCopiedAsItIs() {
        let geometry = FrameGeometry.fit(
            source: CGSize(width: 1024, height: 640), into: CGSize(width: 1024, height: 640))
        XCTAssertEqual(geometry.scale, 1)
        XCTAssertEqual(geometry.covered, CGRect(x: 0, y: 0, width: 1024, height: 640))
    }

    /// A desktop in points on a Retina display doubles and fills the drawable
    func testRetinaDoublesWithoutBars() {
        let geometry = FrameGeometry.fit(
            source: CGSize(width: 1024, height: 640), into: CGSize(width: 2048, height: 1280))
        XCTAssertEqual(geometry.scale, 2)
        XCTAssertEqual(geometry.covered, CGRect(x: 0, y: 0, width: 2048, height: 1280))
    }

    func testWiderDrawableGetsBarsLeftAndRight() {
        let geometry = FrameGeometry.fit(
            source: CGSize(width: 800, height: 600), into: CGSize(width: 1000, height: 600))
        XCTAssertEqual(geometry.scale, 1)
        XCTAssertEqual(geometry.covered, CGRect(x: 100, y: 0, width: 800, height: 600))
    }

    func testTallerDrawableGetsBarsAboveAndBelow() {
        let geometry = FrameGeometry.fit(
            source: CGSize(width: 1600, height: 900), into: CGSize(width: 800, height: 800))
        XCTAssertEqual(geometry.scale, 0.5)
        XCTAssertEqual(geometry.covered, CGRect(x: 0, y: 175, width: 800, height: 450))
    }

    func testEmptySizesCoverNothing() {
        XCTAssertEqual(FrameGeometry.fit(source: .zero, into: CGSize(width: 10, height: 10)).covered, .zero)
        XCTAssertEqual(FrameGeometry.fit(source: CGSize(width: 10, height: 10), into: .zero).covered, .zero)
    }

    /// The mouse maps back to desktop pixels: at the same size a point is its own pixel
    func testSameSizeMapsPointToPixel() {
        let pixel = FrameGeometry.desktopPixel(
            at: CGPoint(x: 10.5, y: 20.9), source: CGSize(width: 1024, height: 640),
            into: CGSize(width: 1024, height: 640))
        XCTAssertEqual(pixel, CGPoint(x: 10, y: 20))
    }

    /// On Retina two drawable pixels make one desktop pixel
    func testRetinaHalvesThePoint() {
        let pixel = FrameGeometry.desktopPixel(
            at: CGPoint(x: 201, y: 101), source: CGSize(width: 1024, height: 640),
            into: CGSize(width: 2048, height: 1280))
        XCTAssertEqual(pixel, CGPoint(x: 100, y: 50))
    }

    /// A point over a bar goes to the nearest edge of the desktop, not past it
    func testBarsLandOnTheNearestEdge() {
        let source = CGSize(width: 800, height: 600)
        let drawable = CGSize(width: 1000, height: 600)
        XCTAssertEqual(
            FrameGeometry.desktopPixel(at: CGPoint(x: 50, y: 300), source: source, into: drawable),
            CGPoint(x: 0, y: 300))
        XCTAssertEqual(
            FrameGeometry.desktopPixel(at: CGPoint(x: 950, y: 599.5), source: source, into: drawable),
            CGPoint(x: 799, y: 599))
        XCTAssertEqual(
            FrameGeometry.desktopPixel(at: CGPoint(x: 100, y: 0), source: source, into: drawable), CGPoint(x: 0, y: 0))
    }

    func testEmptySizesMapNowhere() {
        XCTAssertNil(FrameGeometry.desktopPixel(at: .zero, source: .zero, into: CGSize(width: 10, height: 10)))
        XCTAssertNil(FrameGeometry.desktopPixel(at: .zero, source: CGSize(width: 10, height: 10), into: .zero))
    }
}
