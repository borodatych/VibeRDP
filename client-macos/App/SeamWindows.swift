import AppKit

/// The windows of the host as windows of the Mac, in the Seam mode: each shows its part of the one desktop frame
/// The window chrome is that of Windows, inside the part; the Mac window has no frame of its own
/// The helper moves and restacks them: a window follows its place on the host, section 6 of the specification
@MainActor
final class SeamWindows: NSObject, NSWindowDelegate {
    private let geometry: SeamGeometry
    private let makeDesktop: () -> DesktopView
    private let onDisconnect: () -> Void
    /// The Mac moved or resized a window by itself, tiling or Mission Control: the host gets the new rect
    private let onMove: (UInt64, CGRect) -> Void
    /// The user brought a window forward on the Mac: the host brings it forward too, and the keyboard goes there
    private let onActivate: (UInt64) -> Void
    /// The window with the focus on the host, as the helper last said
    private var foreground: UInt64 = 0
    /// Set while this class places a window: its own moves must not go back to the host
    private var placing = false
    private var shown: [UInt64: (window: SeamWindow, desktop: DesktopView)] = [:]
    private var surface: IOSurfaceRef?
    private var pointer = RemotePointer.system
    /// The windows show only while the link is ready; the desktop shows otherwise
    private(set) var isActive = false

    init(
        geometry: SeamGeometry, makeDesktop: @escaping () -> DesktopView, onDisconnect: @escaping () -> Void,
        onMove: @escaping (UInt64, CGRect) -> Void = { _, _ in },
        onActivate: @escaping (UInt64) -> Void = { _ in }
    ) {
        self.geometry = geometry
        self.makeDesktop = makeDesktop
        self.onDisconnect = onDisconnect
        self.onMove = onMove
        self.onActivate = onActivate
    }

    /// The link is ready: every window of the host comes up in its order
    func activate(_ windows: RemoteWindows) {
        isActive = true
        foreground = windows.foreground
        windows.ordered.reversed().forEach { place($0) }
        restack(windows)
        focus(foreground)
    }

    /// The link is gone: the windows go, and the desktop takes over
    func deactivate() {
        isActive = false
        for id in Array(shown.keys) {
            remove(id)
        }
    }

    /// What one message of the helper changed
    func apply(_ change: RemoteWindows.Change, _ windows: RemoteWindows) {
        guard isActive else { return }
        switch change {
        case .created(let id), .updated(let id):
            if let window = windows.windows[id] {
                place(window)
            }
        case .destroyed(let id):
            remove(id)
        case .order:
            restack(windows)
        case .focus:
            foreground = windows.foreground
            focus(foreground)
        // Icons go to the Dock with the integration of the next stage
        case .icon:
            break
        }
    }

    /// The Mac window of a window of the host, while it shows
    func window(for id: UInt64) -> NSWindow? {
        shown[id]?.window
    }

    func setSurface(_ surface: IOSurfaceRef?) {
        self.surface = surface
        shown.values.forEach { $0.desktop.surface = surface }
    }

    func frameChanged() {
        shown.values.forEach { $0.desktop.frameChanged() }
    }

    func setPointer(_ pointer: RemotePointer) {
        self.pointer = pointer
        shown.values.forEach { $0.desktop.pointer = pointer }
    }

    /// A window the Mac can show: not minimized, with a size, on a monitor; any other is taken away
    private func place(_ remote: RemoteWindow) {
        guard remote.state != .minimized, remote.frame.width > 0, remote.frame.height > 0,
            let frame = geometry.macFrame(of: remote.frame)
        else {
            remove(remote.id)
            return
        }
        let entry = shown[remote.id] ?? open(remote.id)
        entry.window.title = remote.title
        entry.desktop.region = geometry.region(of: remote.frame)
        if entry.window.frame != frame {
            placing = true
            entry.window.setFrame(frame, display: false)
            placing = false
        }
        if !entry.window.isVisible {
            entry.window.orderFront(nil)
        }
    }

    private func open(_ id: UInt64) -> (window: SeamWindow, desktop: DesktopView) {
        let desktop = makeDesktop()
        desktop.surface = surface
        desktop.pointer = pointer
        let window = SeamWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.remoteID = id
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.contentView = desktop
        // The keyboard goes to the desktop view as soon as the window is key, as in the session window
        window.initialFirstResponder = desktop
        window.makeFirstResponder(desktop)
        window.delegate = self
        shown[id] = (window, desktop)
        return (window, desktop)
    }

    private func remove(_ id: UInt64) {
        guard let entry = shown.removeValue(forKey: id) else { return }
        entry.window.delegate = nil
        entry.window.close()
    }

    /// The Mac windows in the order of the host: each goes right under the one above it,
    /// so the stack moves as one and does not jump over the windows of other apps
    private func restack(_ windows: RemoteWindows) {
        let stack = windows.order.compactMap { shown[$0]?.window }.filter(\.isVisible)
        for (upper, lower) in zip(stack, stack.dropFirst()) {
            lower.order(.below, relativeTo: upper.windowNumber)
        }
    }

    /// The focus of the host becomes the key window of the Mac, but only while VibeRDP is the active app:
    /// Windows changing its focus must not take the keyboard from another app of the Mac
    private func focus(_ id: UInt64) {
        guard NSApp.isActive, let window = shown[id]?.window, !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// A window the user made key on the Mac goes forward on the host, unless it is there already
    func windowDidBecomeKey(_ notification: Notification) {
        guard isActive, let window = notification.object as? SeamWindow, let id = window.remoteID,
            id != foreground
        else { return }
        onActivate(id)
    }

    func windowDidMove(_ notification: Notification) {
        moved(notification)
    }

    func windowDidResize(_ notification: Notification) {
        moved(notification)
    }

    /// A frame the Mac gave a window goes to the host, which moves the window there and reports it back
    private func moved(_ notification: Notification) {
        guard !placing, isActive, let window = notification.object as? SeamWindow, let id = window.remoteID,
            let rect = geometry.remoteRect(of: window.frame)
        else { return }
        onMove(id, rect)
    }

    /// The menu command while one of these windows is key: the window delegate is in the responder chain
    @objc func disconnect(_ sender: Any?) {
        onDisconnect()
    }
}

/// A window without a frame that still takes the keyboard: the borderless kind refuses it by default
final class SeamWindow: NSWindow {
    /// The window of the host this one shows; nil for the frameless desktop of a screen
    var remoteID: UInt64?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
