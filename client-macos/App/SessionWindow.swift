import AppKit

/// The window of a running session, as Windows App opens one: the remote desktop, Disconnect in the title bar,
/// and the overlay while a dropped connection is being restored
/// The window of the connections keeps its size and place: the session opens beside it and goes with the session
///
/// The display mode of the connection sets the rest:
/// By the window, the window opens as the last one was and the desktop follows it;
/// zoomed, the window opens over all the free space of the screen, as a double click on its title makes it;
/// in full screen, the window opens in full screen; both follow the window after that;
/// a fixed desktop keeps its size, the window opens as large as the screen lets, and the frame scales into it
/// Every mode but the window one opens on the screen of the connections, where the user started the session
/// On a Retina display a sharp desktop takes its pixels, and a move to a display of another density asks again
/// In full screen on all monitors each screen of the Mac gets a window of its own, each showing its part of one
/// desktop; the monitors stay as they were at the start of the session
/// The Seam mode lays the desktop over all screens at their sizes the same way, with frameless windows over them:
/// they show the desktop until the windows of Windows take over, and again when the helper goes
@MainActor
final class SessionWindowController: NSWindowController, NSWindowDelegate {
    /// The name the window keeps its frame under, so the next session opens where and as large as the last one
    static let frameName = "SessionWindow"
    /// The size of the first session, before any frame is kept
    static let defaultSize = NSSize(width: 1024, height: 640)
    /// The desktop follows the window once the window has stopped for this long:
    /// a drag of the corner would otherwise make the server redraw at every step
    static let resizeDelay: TimeInterval = 0.3
    /// The button sits in the title bar of a standard window: its height, and air from the right edge
    static let titleBarHeight: CGFloat = 28
    static let titleBarMargin: CGFloat = 8

    let desktop: DesktopView
    private let mode: ProfileDisplayMode
    private let fixedSize: DesktopSize
    private let sharp: Bool
    /// The screen the session opens on, as the connections window stood when it started
    private let screen: NSScreen?
    private let onDisconnect: () -> Void
    private let onResize: (DesktopRequest) -> Void
    private var reconnecting: ReconnectingOverlay?
    /// Keeps where the user leaves the window, in the window mode
    private var frameKeeper: WindowFrameKeeper?
    private var resizeTimer: Timer?
    /// The monitors of a session on all screens; nil for one window
    let layout: MonitorLayout?
    /// The windows of the other screens, each with the desktop view of its part
    private var otherWindows: [(window: NSWindow, desktop: DesktopView)] = []
    /// Where the windows of the host stand on the Mac, in the Seam mode
    let seamGeometry: SeamGeometry?
    /// The windows of the host have taken over: showing the session must not bring the desktop back over them
    private var desktopHidden = false

    /// Every desktop view of the session: the one of this window first
    var desktops: [DesktopView] {
        [desktop] + otherWindows.map(\.desktop)
    }

    /// screen is the screen of the connections; nil takes the main one
    /// frameName nil keeps no frame: the tests must not move the window of the app itself
    /// Only the window mode keeps a frame: the other modes have a size and a screen of their own,
    /// and keeping theirs would replace what the window mode comes back with
    init(
        desktop: DesktopView, title: String, mode: ProfileDisplayMode, fixedSize: DesktopSize, sharp: Bool,
        screen: NSScreen?, frameName: String?, frameDefaults: UserDefaults = .standard, allScreens: Bool = false,
        makeDesktop: (() -> DesktopView)? = nil, onDisconnect: @escaping () -> Void,
        onResize: @escaping (DesktopRequest) -> Void
    ) {
        self.desktop = desktop
        self.mode = mode
        self.fixedSize = fixedSize
        self.sharp = sharp
        self.screen = screen ?? NSScreen.main
        self.onDisconnect = onDisconnect
        self.onResize = onResize
        let screens = NSScreen.screens
        let primary = screens.firstIndex { $0 == (screen ?? NSScreen.main) } ?? 0
        if mode == .seam, makeDesktop != nil {
            // The whole of each screen: a window of the host stands where it would on that screen
            let shown = screens.map { (frame: $0.frame, backing: $0.backingScaleFactor) }
            let layout = MonitorLayout(screens: shown, primary: primary, sharp: sharp)
            self.layout = layout
            seamGeometry = SeamGeometry(layout: layout, screens: screens.map(\.frame))
        } else if mode == .fullScreen, allScreens, screens.count > 1, makeDesktop != nil {
            let shown = screens.map { screen in
                (frame: CGRect(origin: screen.frame.origin, size: Self.fullScreenSize(of: screen)),
                 backing: screen.backingScaleFactor)
            }
            layout = MonitorLayout(screens: shown, primary: primary, sharp: sharp)
            seamGeometry = nil
        } else {
            layout = nil
            seamGeometry = nil
        }
        let window = Self.makeWindow(seam: mode == .seam)
        window.title = title
        let content = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        desktop.frame = content.bounds
        desktop.autoresizingMask = [.width, .height]
        content.addSubview(desktop)
        window.contentView = content
        let keepsFrame = mode == .window
        let visible = self.screen?.visibleFrame
        switch mode {
        case .window:
            // The kept frame comes back after the controller takes the window; without one, the middle of the screen
            if let visible {
                window.setFrame(WindowPlacement.centered(window.frame.size, in: visible), display: false)
            }
        case .maximized:
            if let visible {
                window.setFrame(visible, display: false)
            }
        case .fullScreen:
            // Full screen takes the screen the window is on
            if let visible {
                window.setFrame(WindowPlacement.centered(window.frame.size, in: visible), display: false)
            }
        case .fixed:
            let content = visible.map { window.contentRect(forFrameRect: $0).size }
            window.setContentSize(Self.contentSize(for: fixedSize, within: content))
            if let visible {
                window.setFrame(WindowPlacement.centered(window.frame.size, in: visible), display: false)
            }
        case .seam:
            window.setFrame(screens[primary].frame, display: false)
        }
        super.init(window: window)
        window.delegate = self
        // The frame is kept through the controller: a name set on the window alone the controller does not keep,
        // and a controller that cascades moves a new window off the place its frame names
        shouldCascadeWindows = false
        // A frame whose screen is gone gives way to the screen of the connections
        if let frameName, keepsFrame {
            frameKeeper = WindowFrameKeeper(
                window: window, name: frameName, defaults: frameDefaults, fallback: self.screen)
        }
        if let layout, let makeDesktop {
            // This window is the primary monitor; every other screen gets a window with its part of the desktop
            desktop.region = layout.region(of: primary)
            for index in screens.indices where index != primary {
                otherWindows.append(makeOtherWindow(on: screens[index], title: title, desktop: makeDesktop()))
                otherWindows[otherWindows.count - 1].desktop.region = layout.region(of: index)
            }
        } else if mode != .fixed {
            desktop.onResize = { [weak self] size in self?.desktopResized(to: size) }
        }
    }

    /// A window of one more screen: full screen there, closing it ends the session as closing the first one does
    private func makeOtherWindow(on screen: NSScreen, title: String, desktop: DesktopView) -> (NSWindow, DesktopView) {
        let window = Self.makeWindow(seam: mode == .seam)
        window.title = title
        let content = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        desktop.frame = content.bounds
        desktop.autoresizingMask = [.width, .height]
        content.addSubview(desktop)
        window.contentView = content
        if mode == .seam {
            window.setFrame(screen.frame, display: false)
        } else {
            window.setFrame(WindowPlacement.centered(window.frame.size, in: screen.visibleFrame), display: false)
        }
        window.delegate = self
        return (window, desktop)
    }

    /// A standard window that can go full screen, or a frameless one over a whole screen in the Seam mode
    private static func makeWindow(seam: Bool) -> NSWindow {
        let window: NSWindow
        if seam {
            window = SeamWindow(
                contentRect: NSRect(origin: .zero, size: defaultSize), styleMask: [.borderless], backing: .buffered,
                defer: false)
        } else {
            window = NSWindow(
                contentRect: NSRect(origin: .zero, size: defaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
        // The controller owns the window; AppKit must not free it behind that reference when it closes
        window.isReleasedWhenClosed = false
        return window
    }

    /// In the Seam mode the desktop steps aside while the windows of the host show, and comes back when they go
    func setDesktopHidden(_ hidden: Bool) {
        guard mode == .seam, let window else { return }
        desktopHidden = hidden
        for shown in [window] + otherWindows.map(\.window) {
            if hidden {
                shown.orderOut(nil)
            } else {
                shown.orderFront(nil)
            }
        }
        if !hidden {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(desktop)
        }
    }

    /// A new surface of the engine goes to every view: each shows its part of it
    func setSurface(_ surface: IOSurfaceRef?) {
        desktops.forEach { $0.surface = surface }
    }

    func frameChanged() {
        desktops.forEach { $0.frameChanged() }
    }

    func setPointer(_ pointer: RemotePointer) {
        desktops.forEach { $0.pointer = pointer }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the window is built in code")
    }

    /// The desktop the session asks for when it connects, so it needs no change once the window shows
    var desktopRequest: DesktopRequest {
        let points = Self.desktopSize(
            mode: mode, fixed: fixedSize, content: window?.contentLayoutRect.size ?? Self.defaultSize,
            fullScreen: screen.map(Self.fullScreenSize(of:)) ?? Self.defaultSize)
        // All monitors: the desktop is the rectangle around them, and each goes with its place and scale
        if let layout {
            let primary = layout.monitors.first(where: \.primary)
            return DesktopRequest(
                size: layout.bounds.size, scale: primary?.scale ?? DesktopRequest.standardScale,
                monitors: layout.coreMonitors)
        }
        // A fixed desktop is in pixels of Windows already, and the window stretches it as any other frame
        guard mode != .fixed else { return DesktopRequest(size: points) }
        let backing = (mode == .fullScreen ? screen : window?.screen ?? screen)?.backingScaleFactor ?? 1
        return DesktopRequest.points(points, backing: backing, sharp: sharp)
    }

    /// The desktop of a mode: the content of the window, zoomed or not, the screen in full screen, or the fixed size
    /// Sizes are in points of the Mac; desktopRequest turns them into pixels of the display
    static func desktopSize(
        mode: ProfileDisplayMode, fixed: DesktopSize, content: CGSize, fullScreen: CGSize
    ) -> CGSize {
        switch mode {
        case .window, .maximized: CGSize(width: content.width.rounded(), height: content.height.rounded())
        case .fullScreen: CGSize(width: fullScreen.width.rounded(), height: fullScreen.height.rounded())
        case .fixed: fixed.clamped.cgSize
        // The layout gives the desktop of the Seam mode; this is only the screen, should there be no layout
        case .seam: CGSize(width: fullScreen.width.rounded(), height: fullScreen.height.rounded())
        }
    }

    /// What a window in full screen shows of a screen: all of it but the strip of a camera housing at the top
    static func fullScreenSize(of screen: NSScreen) -> CGSize {
        CGSize(width: screen.frame.width, height: screen.frame.height - screen.safeAreaInsets.top)
    }

    /// The window of a fixed desktop: as large as the desktop, or smaller in its proportions on a smaller screen
    static func contentSize(for fixed: DesktopSize, within visible: CGSize?) -> CGSize {
        let size = fixed.clamped.cgSize
        guard let visible, visible.width > 0, visible.height > 0 else { return size }
        let scale = min(1, visible.width / size.width, visible.height / size.height)
        return CGSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
    }

    /// The user is in: the window comes up with the keyboard on the desktop, in full screen when the mode says so
    func show() {
        guard let window, !window.isVisible, !desktopHidden else { return }
        showWindow(nil)
        if mode == .fullScreen && !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        for other in otherWindows {
            other.window.orderFront(nil)
            if mode != .seam {
                other.window.toggleFullScreen(nil)
            }
        }
        window.makeFirstResponder(desktop)
        // A frameless window has no title bar to put the button in: the menu disconnects
        if mode != .seam {
            showDisconnectButton()
        }
        Diagnostics.info(
            "frame", "desktop shown in \(desktop.bounds.size), backing scale \(window.backingScaleFactor)")
    }

    /// The session is over: the window goes, and nothing it still waits for fires
    func end() {
        resizeTimer?.invalidate()
        resizeTimer = nil
        frameKeeper?.save()
        frameKeeper?.stop()
        hideReconnecting()
        for other in otherWindows {
            other.window.delegate = nil
            other.window.close()
        }
        otherWindows = []
        close()
    }

    var isReconnecting: Bool { reconnecting != nil }

    func showReconnecting(host: String) {
        guard reconnecting == nil, let content = window?.contentView else { return }
        let overlay = ReconnectingOverlay(host: host) { [weak self] in self?.onDisconnect() }
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay)
        reconnecting = overlay
    }

    func showReconnectingAttempt(_ attempt: UInt32, of maxAttempts: UInt32) {
        reconnecting?.show(attempt: attempt, of: maxAttempts)
    }

    func hideReconnecting() {
        reconnecting?.removeFromSuperview()
        reconnecting = nil
    }

    /// The menu command while this window is key: the connections window is not in its responder chain
    @objc func disconnect(_ sender: Any?) {
        onDisconnect()
    }

    /// A move to a display of another density asks for the desktop at its pixels
    func windowDidChangeBackingProperties(_ notification: Notification) {
        if mode != .fixed && layout == nil {
            desktopResized(to: desktop.bounds.size)
        }
    }

    /// The close button ends the session at once: Windows keeps the session, and the next connection returns to it
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onDisconnect()
        return true
    }

    /// The window stopped changing: the server gets its size, the frame scales into the window meanwhile
    private func desktopResized(to size: CGSize) {
        resizeTimer?.invalidate()
        resizeTimer = Timer.scheduledTimer(withTimeInterval: Self.resizeDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                let request = DesktopRequest.points(
                    size, backing: self.window?.backingScaleFactor ?? 1, sharp: self.sharp)
                Diagnostics.info("frame", "asking for a desktop of \(request.size) at \(request.scale)% for \(size)")
                self.onResize(request)
            }
        }
    }

    /// Disconnect in the title bar, where it shows in full screen too, when the menu bar hides
    private func showDisconnectButton() {
        guard let window, window.titlebarAccessoryViewControllers.isEmpty else { return }
        let button = NSButton(
            title: Localization.text(.connectionActionDisconnect),
            image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil) ?? NSImage(),
            target: self, action: #selector(disconnect(_:)))
        button.bezelStyle = .accessoryBarAction
        button.imagePosition = .imageLeading
        let accessory = NSTitlebarAccessoryViewController()
        let holder = NSView()
        holder.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -Self.titleBarMargin),
        ])
        holder.frame.size = NSSize(width: button.fittingSize.width + Self.titleBarMargin, height: Self.titleBarHeight)
        accessory.view = holder
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
    }
}
