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
    private var resizeTimer: Timer?

    /// screen is the screen of the connections; nil takes the main one
    /// frameName nil keeps no frame: the tests must not move the window of the app itself
    /// Only the window mode keeps a frame: the other modes have a size and a screen of their own,
    /// and keeping theirs would replace what the window mode comes back with
    init(
        desktop: DesktopView, title: String, mode: ProfileDisplayMode, fixedSize: DesktopSize, sharp: Bool,
        screen: NSScreen?, frameName: String?, onDisconnect: @escaping () -> Void,
        onResize: @escaping (DesktopRequest) -> Void
    ) {
        self.desktop = desktop
        self.mode = mode
        self.fixedSize = fixedSize
        self.sharp = sharp
        self.screen = screen ?? NSScreen.main
        self.onDisconnect = onDisconnect
        self.onResize = onResize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = title
        window.collectionBehavior.insert(.fullScreenPrimary)
        // The controller owns the window; AppKit must not free it behind that reference when it closes
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        desktop.frame = content.bounds
        desktop.autoresizingMask = [.width, .height]
        content.addSubview(desktop)
        window.contentView = content
        let keepsFrame = mode == .window
        let visible = self.screen?.visibleFrame
        switch mode {
        case .window:
            if !(frameName.map { window.setFrameUsingName($0) } ?? false), let visible {
                window.setFrame(Self.centered(window.frame.size, in: visible), display: false)
            }
        case .maximized:
            if let visible {
                window.setFrame(visible, display: false)
            }
        case .fullScreen:
            // Full screen takes the screen the window is on
            if let visible {
                window.setFrame(Self.centered(window.frame.size, in: visible), display: false)
            }
        case .fixed:
            let content = visible.map { window.contentRect(forFrameRect: $0).size }
            window.setContentSize(Self.contentSize(for: fixedSize, within: content))
            if let visible {
                window.setFrame(Self.centered(window.frame.size, in: visible), display: false)
            }
        }
        super.init(window: window)
        window.delegate = self
        // The frame is kept through the controller: a name set on the window alone the controller does not keep,
        // and a controller that cascades moves a new window off the place its frame names
        shouldCascadeWindows = false
        if let frameName, keepsFrame {
            windowFrameAutosaveName = frameName
        }
        if mode != .fixed {
            desktop.onResize = { [weak self] size in self?.desktopResized(to: size) }
        }
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
        // A fixed desktop is in pixels of Windows already, and the window stretches it as any other frame
        guard mode != .fixed else { return DesktopRequest(size: points) }
        let backing = (mode == .fullScreen ? screen : window?.screen ?? screen)?.backingScaleFactor ?? 1
        return DesktopRequest.points(points, backing: backing, sharp: sharp)
    }

    /// The desktop of a mode: the content of the window, zoomed or not, the screen in full screen, or the fixed size
    /// Sizes are in points of the Mac; the pixels of the display are task 3.2
    static func desktopSize(
        mode: ProfileDisplayMode, fixed: DesktopSize, content: CGSize, fullScreen: CGSize
    ) -> CGSize {
        switch mode {
        case .window, .maximized: CGSize(width: content.width.rounded(), height: content.height.rounded())
        case .fullScreen: CGSize(width: fullScreen.width.rounded(), height: fullScreen.height.rounded())
        case .fixed: fixed.clamped.cgSize
        }
    }

    /// A frame of this size in the middle of an area, kept inside it
    static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)
        return CGRect(
            x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
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
        guard let window, !window.isVisible else { return }
        showWindow(nil)
        if mode == .fullScreen && !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        window.makeFirstResponder(desktop)
        showDisconnectButton()
        Diagnostics.info(
            "frame", "desktop shown in \(desktop.bounds.size), backing scale \(window.backingScaleFactor)")
    }

    /// The session is over: the window goes, and nothing it still waits for fires
    func end() {
        resizeTimer?.invalidate()
        resizeTimer = nil
        hideReconnecting()
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
        if mode != .fixed {
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
