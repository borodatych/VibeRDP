import AppKit
import VibeRDPCore
import XCTest

@testable import VibeRDP

/// The screens of the Mac as the monitors of one Windows desktop
@MainActor
final class MonitorLayoutTests: XCTestCase {
    /// The two screens of the owner: MateView at 2x left of ZEUSLAP at 1x; ZEUSLAP, the screen of the connections,
    /// becomes the primary monitor at 0,0, and MateView stands to its left at its pixels
    func testSideBySideAtTheirDensities() {
        let screens = [
            (frame: CGRect(x: 0, y: 0, width: 1920, height: 1200), backing: CGFloat(1)),
            (frame: CGRect(x: -3008, y: -181, width: 3008, height: 2005), backing: CGFloat(2)),
        ]
        let layout = MonitorLayout(screens: screens, primary: 0, sharp: true)
        XCTAssertEqual(
            layout.monitors,
            [
                .init(frame: CGRect(x: 0, y: 0, width: 1920, height: 1200), scale: 100, primary: true),
                .init(frame: CGRect(x: -6016, y: 0, width: 6016, height: 4010), scale: 200, primary: false),
            ])
        XCTAssertEqual(layout.bounds, CGRect(x: -6016, y: 0, width: 7936, height: 4010))
        XCTAssertEqual(layout.region(of: 1), CGRect(x: 0, y: 0, width: 6016, height: 4010))
        XCTAssertEqual(layout.region(of: 0), CGRect(x: 6016, y: 0, width: 1920, height: 1200))
        XCTAssertEqual(
            layout.coreMonitors.map(\.x), [0, -6016], "the core gets the places, the primary at 0,0")
    }

    /// The primary may be the left one: the other then stands to its right
    func testPrimaryOnTheLeft() {
        let screens = [
            (frame: CGRect(x: 0, y: 0, width: 1920, height: 1200), backing: CGFloat(1)),
            (frame: CGRect(x: -3008, y: -181, width: 3008, height: 2005), backing: CGFloat(2)),
        ]
        let layout = MonitorLayout(screens: screens, primary: 1, sharp: true)
        XCTAssertEqual(layout.monitors[1].frame.origin, .zero)
        XCTAssertEqual(layout.monitors[0].frame, CGRect(x: 6016, y: 0, width: 1920, height: 1200))
        XCTAssertEqual(layout.bounds.origin, .zero)
    }

    /// Screens one over the other stack from the top, as Windows counts down; without sharpness points are pixels
    func testStackedWithoutSharpness() {
        let screens = [
            (frame: CGRect(x: 0, y: 0, width: 1920, height: 1200), backing: CGFloat(2)),
            (frame: CGRect(x: 200, y: 1200, width: 1600, height: 900), backing: CGFloat(1)),
        ]
        let layout = MonitorLayout(screens: screens, primary: 0, sharp: false)
        XCTAssertEqual(layout.monitors[1].frame, CGRect(x: 0, y: -900, width: 1600, height: 900))
        XCTAssertEqual(layout.monitors[0].frame, CGRect(x: 0, y: 0, width: 1920, height: 1200))
        XCTAssertEqual(layout.monitors.map(\.scale), [100, 100])
        XCTAssertEqual(layout.region(of: 0), CGRect(x: 0, y: 900, width: 1920, height: 1200))
    }
}
