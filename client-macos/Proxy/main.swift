import AppKit

/// A stand-in on the Mac for one program of the Windows host, in the Seam mode of VibeRDP
///
/// VibeRDP copies this app once a program, gives the copy the name and the icon of the program and starts it:
/// the copy has no windows, only its icon in the Dock and in Cmd-Tab
/// Choosing the icon brings the windows of the program forward in VibeRDP; quitting it closes them on the host
/// The copy ends when VibeRDP asks, and when VibeRDP itself ends
@MainActor
final class ProxyDelegate: NSObject, NSApplicationDelegate {
    /// The names both sides post under, with the bundle identifier of the copy as the object
    static let activated = Notification.Name("tech.vibebrains.viberdp.proxy.activated")
    static let quitRequested = Notification.Name("tech.vibebrains.viberdp.proxy.quitRequested")
    static let quit = Notification.Name("tech.vibebrains.viberdp.proxy.quit")

    private let key = Bundle.main.bundleIdentifier ?? ""
    private var parentExit: DispatchSourceProcess?
    /// Set when VibeRDP asked the copy to go: its quit is not the user's and closes nothing on the host
    private var leaving = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Self.quit, object: key, queue: .main) { _ in
            MainActor.assumeIsolated {
                self.leaving = true
                NSApp.terminate(nil)
            }
        }
        watchParent()
    }

    /// VibeRDP names its process on the command line: the copy must not outlive it
    private func watchParent() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--parent"), index + 1 < arguments.count,
            let parent = pid_t(arguments[index + 1]), kill(parent, 0) == 0
        else {
            leaving = true
            NSApp.terminate(nil)
            return
        }
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                self.leaving = true
                NSApp.terminate(nil)
            }
        }
        source.resume()
        parentExit = source
    }

    /// A click on the Dock icon or a choice in Cmd-Tab: VibeRDP brings the windows of the program forward
    func applicationDidBecomeActive(_ notification: Notification) {
        post(Self.activated)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        post(Self.activated)
        return false
    }

    /// Quit from the Dock: the windows of the program close on the host, as closing them there would
    func applicationWillTerminate(_ notification: Notification) {
        if !leaving {
            post(Self.quitRequested)
        }
    }

    private func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: key, userInfo: nil, deliverImmediately: true)
    }
}

let application = NSApplication.shared
let delegate = ProxyDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
