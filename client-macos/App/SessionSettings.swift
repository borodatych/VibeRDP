import Foundation
import Observation

/// Settings of every session, roadmap 8.1: how fast a trackpad scrolls, how often the Mac clipboard is looked at,
/// and which display mode a new connection gets
/// Each value stays within its range, whatever the defaults hold, and the default is what the app did before
@MainActor
@Observable
final class SessionSettings {
    static let scrollSpeedRange = 0.5...4.0
    static let defaultScrollSpeed = 1.0
    static let clipboardIntervalRange = 0.1...2.0
    static let defaultClipboardInterval = ClipboardBridge.pollInterval
    static let defaultNewConnectionMode = ProfileDisplayMode.window

    private static let scrollSpeedKey = "sessionScrollSpeed"
    private static let clipboardIntervalKey = "sessionClipboardInterval"
    private static let newConnectionModeKey = "sessionNewConnectionMode"

    @ObservationIgnored private let defaults: UserDefaults

    /// A multiplier of the scrolling of trackpads and the Magic Mouse; a wheel keeps a notch a line
    var scrollSpeed: Double {
        didSet { defaults.set(scrollSpeed, forKey: Self.scrollSpeedKey) }
    }

    /// Seconds between two looks at the Mac clipboard; a new session takes the value
    var clipboardInterval: Double {
        didSet { defaults.set(clipboardInterval, forKey: Self.clipboardIntervalKey) }
    }

    var newConnectionMode: ProfileDisplayMode {
        didSet { defaults.set(newConnectionMode.rawValue, forKey: Self.newConnectionModeKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        scrollSpeed = Self.clamped(
            defaults.object(forKey: Self.scrollSpeedKey) as? Double ?? Self.defaultScrollSpeed, to: Self.scrollSpeedRange)
        clipboardInterval = Self.clamped(
            defaults.object(forKey: Self.clipboardIntervalKey) as? Double ?? Self.defaultClipboardInterval,
            to: Self.clipboardIntervalRange)
        newConnectionMode =
            defaults.string(forKey: Self.newConnectionModeKey).flatMap(ProfileDisplayMode.init(rawValue:))
            ?? Self.defaultNewConnectionMode
    }

    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
    }
}
