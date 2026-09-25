import XCTest

@testable import VibeRDP

/// The wheel units follow the speed constants, so the tests hold whatever speed the live checks settle on
final class WheelAccumulatorTests: XCTestCase {
    func testClassicWheelLineIsOneNotch() {
        var wheel = WheelAccumulator()
        XCTAssertTrue(wheel.units(deltaX: 0, deltaY: 1, precise: false) == (120, 0))
        XCTAssertTrue(wheel.units(deltaX: 0, deltaY: -2, precise: false) == (-240, 0))
    }

    func testTrackpadPointsFollowTheSpeed() {
        var wheel = WheelAccumulator()
        let units = wheel.units(deltaX: 0, deltaY: 10, precise: true)
        XCTAssertEqual(units.vertical, Int32(10 * WheelAccumulator.unitsPerPoint))
    }

    /// A slow scroll sends nothing at first and a unit once the fractions add up to one
    func testFractionsCarryOver() {
        var wheel = WheelAccumulator()
        let step = 0.4 / WheelAccumulator.unitsPerPoint
        XCTAssertEqual(wheel.units(deltaX: 0, deltaY: step, precise: true).vertical, 0)
        XCTAssertEqual(wheel.units(deltaX: 0, deltaY: step, precise: true).vertical, 0)
        XCTAssertEqual(wheel.units(deltaX: 0, deltaY: step, precise: true).vertical, 1)
    }

    /// Content moving right on the Mac is a scroll to the left, which Windows counts as negative
    func testHorizontalIsMirrored() {
        var wheel = WheelAccumulator()
        XCTAssertTrue(wheel.units(deltaX: 1, deltaY: 0, precise: false) == (0, -120))
        XCTAssertTrue(wheel.units(deltaX: -0.5, deltaY: 0, precise: false) == (0, 60))
    }
}
