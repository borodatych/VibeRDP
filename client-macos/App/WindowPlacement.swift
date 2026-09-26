import AppKit

/// Where a window opens: where the user left it, as large as it was, while that place is still on a screen
/// A place the screens no longer have, as after a display was unplugged, gives way to a screen that is there;
/// from then on the window keeps the place the user gives it
@MainActor
enum WindowPlacement {
    /// The strip of the title bar that must lie on a screen for the user to take the window and move it
    static let grip = CGSize(width: 100, height: 20)

    /// Puts the window at its kept frame and keeps it from now on; false when it went to the fallback screen instead
    @discardableResult
    static func restore(_ window: NSWindow, name: String, fallback: NSScreen?) -> Bool {
        let restored = window.setFrameUsingName(name)
        window.setFrameAutosaveName(name)
        if restored && isReachable(window.frame, on: NSScreen.screens.map(\.visibleFrame)) {
            return true
        }
        if let area = fallback?.visibleFrame {
            window.setFrame(centered(window.frame.size, in: area), display: false)
        }
        return false
    }

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
