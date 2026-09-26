import XCTest

@testable import VibeRDP

/// The settings of every session: kept, held within their ranges, and applied where they belong
@MainActor
final class SessionSettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testDefaultsAreWhatTheAppDidBefore() {
        let settings = SessionSettings(defaults: defaults())
        XCTAssertEqual(settings.scrollSpeed, 1)
        XCTAssertEqual(settings.clipboardInterval, ClipboardBridge.pollInterval)
        XCTAssertEqual(settings.newConnectionMode, .window)
    }

    func testValuesAreKeptAndHeldInRange() {
        let store = defaults()
        let settings = SessionSettings(defaults: store)
        settings.scrollSpeed = 2.5
        settings.newConnectionMode = .seam
        XCTAssertEqual(SessionSettings(defaults: store).scrollSpeed, 2.5)
        XCTAssertEqual(SessionSettings(defaults: store).newConnectionMode, .seam)
        store.set(100.0, forKey: "sessionScrollSpeed")
        store.set(-1.0, forKey: "sessionClipboardInterval")
        store.set("unknown", forKey: "sessionNewConnectionMode")
        let read = SessionSettings(defaults: store)
        XCTAssertEqual(read.scrollSpeed, SessionSettings.scrollSpeedRange.upperBound)
        XCTAssertEqual(read.clipboardInterval, SessionSettings.clipboardIntervalRange.lowerBound)
        XCTAssertEqual(read.newConnectionMode, .window)
    }

    func testScrollSpeedMultipliesTrackpadsOnly() {
        var wheel = WheelAccumulator()
        XCTAssertEqual(wheel.units(deltaX: 0, deltaY: 10, precise: true, speed: 2).vertical, 40)
        XCTAssertEqual(wheel.units(deltaX: 0, deltaY: 1, precise: false, speed: 2).vertical, 120)
    }
}
