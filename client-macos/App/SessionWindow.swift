import AppKit

/// The window of a running session, as Windows App opens one: the remote desktop, Disconnect in the title bar,
/// and the overlay while a dropped connection is being restored
/// The window of the connections keeps its size and place: the session opens beside it and goes with the session
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
    private let onDisconnect: () -> Void
    private let onResize: (CGSize) -> Void
    private var reconnecting: ReconnectingOverlay?
    private var resizeTimer: Timer?

    /// frameName nil keeps no frame: the tests must not move the window of the app itself
    init(
        desktop: DesktopView, title: String, frameName: String?, onDisconnect: @escaping () -> Void,
        onResize: @escaping (CGSize) -> Void
    ) {
        self.desktop = desktop
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
        if let frameName {
            if !window.setFrameUsingName(frameName) {
                window.center()
            }
            window.setFrameAutosaveName(frameName)
        } else {
            window.center()
        }
        super.init(window: window)
        window.delegate = self
        desktop.onResize = { [weak self] size in self?.desktopResized(to: size) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the window is built in code")
    }

    /// The desktop the session asks for when it connects: the window in points; the pixels of the display are task 3.2
    var desktopSize: CGSize {
        let size = window?.contentLayoutRect.size ?? Self.defaultSize
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    /// The user is in: the window comes up with the keyboard on the desktop
    func show() {
        guard let window, !window.isVisible else { return }
        showWindow(nil)
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
                let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
                Diagnostics.info("frame", "asking for a desktop of \(rounded)")
                self.onResize(rounded)
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
