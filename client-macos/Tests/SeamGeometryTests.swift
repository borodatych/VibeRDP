import XCTest

@testable import VibeRDP

/// Windows of the host placed on the screens of the Mac, as the Seam mode lays the desktop over them
final class SeamGeometryTests: XCTestCase {
    /// The screens of the owner: a laptop of 1920 by 1200 points at 1x, the main one, and a Retina monitor to its
    /// right, 1504 by 1002.5 points at 2x, both from the bottom as the Mac counts
    private let laptop = CGRect(x: 0, y: 0, width: 1920, height: 1200)
    private let monitor = CGRect(x: 1920, y: 0, width: 1504, height: 1002)

    private func geometry(sharp: Bool) -> SeamGeometry {
        let layout = MonitorLayout(
            screens: [(frame: laptop, backing: 1), (frame: monitor, backing: 2)], primary: 0, sharp: sharp)
        return SeamGeometry(layout: layout, screens: [laptop, monitor])
    }

    func testWindowOnThePrimaryMonitor() {
        let frame = geometry(sharp: true).macFrame(of: CGRect(x: 100, y: 50, width: 800, height: 600))
        XCTAssertEqual(frame, CGRect(x: 100, y: 1200 - 50 - 600, width: 800, height: 600))
    }

    func testWindowOnARetinaMonitorTakesItsDensity() {
        // The Retina monitor is 3008 pixels wide and starts right after the 1920 of the laptop
        let frame = geometry(sharp: true).macFrame(of: CGRect(x: 1920 + 200, y: 100, width: 1000, height: 400))
        XCTAssertEqual(frame, CGRect(x: 1920 + 100, y: 1002 - 50 - 200, width: 500, height: 200))
    }

    func testWindowOverTwoMonitorsGoesWhereMostOfItIs() {
        let frame = geometry(sharp: true).macFrame(of: CGRect(x: 1900, y: 0, width: 400, height: 100))
        XCTAssertEqual(frame?.minX, 1920 - 10)
        XCTAssertEqual(frame?.width, 200)
    }

    func testWindowOffEveryMonitorHasNoPlace() {
        XCTAssertNil(geometry(sharp: true).macFrame(of: CGRect(x: -32000, y: -32000, width: 160, height: 28)))
    }

    func testRegionCountsFromTheTopLeftOfAllMonitors() {
        let left = CGRect(x: -1504, y: 0, width: 1504, height: 1002)
        let layout = MonitorLayout(
            screens: [(frame: left, backing: 1), (frame: laptop, backing: 1)], primary: 1, sharp: false)
        let geometry = SeamGeometry(layout: layout, screens: [left, laptop])
        // The primary is on the right, so the monitor on its left starts at a negative x
        XCTAssertEqual(layout.bounds.minX, -1504)
        XCTAssertEqual(
            geometry.region(of: CGRect(x: -100, y: 10, width: 50, height: 50)),
            CGRect(x: 1404, y: 10, width: 50, height: 50))
    }
}
