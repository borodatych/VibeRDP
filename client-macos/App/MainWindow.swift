import AppKit

/// The main window: the list of connections; a session opens a window of its own
/// It opens where the user left it and as large, or on the screen with the menu bar when that place is gone
@MainActor
enum MainWindow {
    static let defaultSize = NSSize(width: 1024, height: 640)
    /// The name the window keeps its frame under
    static let frameName = "MainWindow"

    static func make(title: String, content: NSViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            // The sidebar runs up under the title bar, as in the other apps with a sidebar
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = title
        window.toolbarStyle = .unified
        window.contentViewController = content
        window.autorecalculatesKeyViewLoop = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        // The delegate owns the window; AppKit must not free it behind that reference when it closes
        window.isReleasedWhenClosed = false
        WindowPlacement.restore(window, name: frameName, fallback: WindowPlacement.primaryScreen)
        return window
    }
}
