import AppKit

/// Lifecycle of the app: builds the menu bar and the main window once launching finishes
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = MainMenu(appName: Self.appName)
        NSApp.mainMenu = menu.bar
        NSApp.windowsMenu = menu.windowMenu

        let window = MainWindow.make(title: Self.appName)
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Product name from Info.plist: a name, so no language translates it
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    }
}
