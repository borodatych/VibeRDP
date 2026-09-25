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
}
