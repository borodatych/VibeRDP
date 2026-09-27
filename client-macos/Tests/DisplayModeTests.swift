import XCTest

@testable import VibeRDP

/// The Windows windows come and go with FEATURE_WINDOWS of build.env: off in the releases 1.x, on for 2.0
final class DisplayModeTests: XCTestCase {
    func testOfferedModesFollowTheBuild() {
        XCTAssertEqual(ProfileDisplayMode.offered.contains(.seam), ProfileDisplayMode.windowsMode)
        XCTAssertEqual(
            ProfileDisplayMode.offered.filter { $0 != .seam }, ProfileDisplayMode.allCases.filter { $0 != .seam })
    }

    func testModeNotOfferedOpensByTheWindow() {
        XCTAssertEqual(ProfileDisplayMode.seam.effective, ProfileDisplayMode.windowsMode ? .seam : .window)
        for mode in ProfileDisplayMode.allCases where mode != .seam {
            XCTAssertEqual(mode.effective, mode)
        }
    }
}
