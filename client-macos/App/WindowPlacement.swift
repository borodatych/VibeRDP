import AppKit

/// Where a window opens: where the user left it, on the same screen and as large as it was, while that place is
/// still on a screen; a place the screens no longer have, as after a display was unplugged, gives way to a screen
/// that is there, and from then on the window keeps the place the user gives it
@MainActor
enum WindowPlacement {
    /// The strip of the title bar that must lie on a screen for the user to take the window and move it
    static let grip = CGSize(width: 100, height: 20)

    /// The top of the frame, where the title bar is, lies on one of the screens widely enough to be taken
    static func isReachable(_ frame: CGRect, on screens: [CGRect]) -> Bool {
        let titleBar = CGRect(x: frame.minX, y: frame.maxY - grip.height, width: frame.width, height: grip.height)
        return screens.contains { screen in
            let common = screen.intersection(titleBar)
            return !common.isNull && common.width >= grip.width && common.height >= grip.height
        }
    }

    /// A frame of this size in the middle of an area, kept inside it
    static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)
        return CGRect(
            x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
    }

    /// The screen with the menu bar: the one a window without a place goes to
    static var primaryScreen: NSScreen? {
        NSScreen.screens.first
    }
}

/// Keeps the frame of a window as the user leaves it and puts the window back there when it opens
///
/// The frame is kept alone, in screen coordinates, not with the screen it was on as AppKit keeps it:
/// AppKit takes a screen whose free area changed since, as when the Dock moved, for a screen that is gone,
/// and moves the window to the main one; here the frame comes back as it was while its title bar is on a screen
@MainActor
final class WindowFrameKeeper {
    /// The key a frame lives under: window.<name>.frame
    static func key(for name: String) -> String {
        "window.\(name).frame"
    }

    /// Where AppKit kept the frame before, read once so the place is not lost
    static func legacyKey(for name: String) -> String {
        "NSWindow Frame \(name)"
    }

    private let window: NSWindow
    private let name: String
    private let key: String
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []
    /// The window took its kept frame; false when it went to the fallback screen
    private(set) var restored = false

    init(window: NSWindow, name: String, defaults: UserDefaults = .standard, fallback: NSScreen?) {
        self.window = window
        self.name = name
        self.defaults = defaults
        key = Self.key(for: name)
        restored = restore(legacy: Self.legacyKey(for: name), fallback: fallback)
        save()
        let names = [
            NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.willCloseNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            }
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.logPlace("kept on close") }
            })
    }

    /// Where the window stands and on which screen, for the diagnostics log: a window the system moves after
    /// it opens shows here, with the screens it had then
    func logPlace(_ event: String) {
        let screen = window.screen?.localizedName ?? "none"
        Diagnostics.info(
            "window",
            "\(name) \(event): \(NSStringFromRect(window.frame)) on \(screen), active space \(window.isOnActiveSpace)")
    }

    /// No more saving: the window goes with its owner
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// The frame as it is now; a window in full screen keeps the frame it will come back to
    func save() {
        guard !window.styleMask.contains(.fullScreen), window.frame.width > 0, window.frame.height > 0 else { return }
        defaults.set(NSStringFromRect(window.frame), forKey: key)
    }

    private func restore(legacy: String, fallback: NSScreen?) -> Bool {
        let screens = NSScreen.screens.map(\.visibleFrame)
        let kept = Self.frame(defaults.string(forKey: key)) ?? Self.legacyFrame(defaults.string(forKey: legacy))
        let names = NSScreen.screens.map { "\($0.localizedName) \(NSStringFromRect($0.visibleFrame))" }
        Diagnostics.info(
            "window",
            "\(name) opens: kept \(kept.map(NSStringFromRect) ?? "none"), screens \(names.joined(separator: ", "))")
        if let frame = kept, WindowPlacement.isReachable(frame, on: screens) {
            window.setFrame(frame, display: false)
            return true
        }
        if let area = fallback?.visibleFrame {
            window.setFrame(WindowPlacement.centered(window.frame.size, in: area), display: false)
        }
        Diagnostics.info("window", "\(name) goes to the fallback screen: \(NSStringFromRect(window.frame))")
        return false
    }

    static func frame(_ string: String?) -> CGRect? {
        guard let string else { return nil }
        let frame = NSRectFromString(string)
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    /// AppKit writes the frame and then the screen: "x y width height screenX screenY screenWidth screenHeight"
    static func legacyFrame(_ string: String?) -> CGRect? {
        let numbers = (string ?? "").split(separator: " ").compactMap { Double($0) }
        guard numbers.count >= 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }
}
