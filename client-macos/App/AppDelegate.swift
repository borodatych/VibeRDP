import AppKit

/// Lifecycle of the app: builds the menu bar and the main window once launching finishes
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindow: NSWindow?
    private(set) var settingsWindow: SettingsWindowController?
    let keyboard = KeyboardSettingsStore()
    private var menu: MainMenu?
    private var keyboardObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = MainMenu(appName: Self.appName)
        menu.apply(keyboard.settings)
        NSApp.mainMenu = menu.bar
        NSApp.windowsMenu = menu.windowMenu
        self.menu = menu
        // The store posts on the main thread, and without a queue the menu follows before the change returns
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: KeyboardSettingsStore.didChange, object: keyboard, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menu?.apply(self.keyboard.settings)
            }
        }

        let profiles = ProfileStore(passwords: KeychainPasswordStore())
        let content = ConnectionViewController(trusted: TrustedCertificates(), keyboard: keyboard, profiles: profiles)
        let window = MainWindow.make(title: Self.appName, content: content)
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
        NSApp.activate()
    }

    /// The menu command: one settings window, made when first asked for
    @objc func showSettings(_ sender: Any?) {
        let controller = settingsWindow ?? SettingsWindowController(keyboard: keyboard)
        settingsWindow = controller
        controller.showWindow(sender)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Product name from Info.plist: a name, so no language translates it
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    }
}
