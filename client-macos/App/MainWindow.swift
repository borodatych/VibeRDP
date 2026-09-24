import AppKit

/// The main window: the connection form until the session view arrives (roadmap 1.2)
@MainActor
enum MainWindow {
    static let defaultSize = NSSize(width: 1024, height: 640)

    static func make(title: String, content: NSViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = title
        window.contentViewController = content
        window.autorecalculatesKeyViewLoop = true
        // The delegate owns the window; AppKit must not free it behind that reference when it closes
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
