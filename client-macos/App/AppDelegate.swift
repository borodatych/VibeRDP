import AppKit

/// Lifecycle of the app: builds the menu bar and the main window once launching finishes
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindow: NSWindow?
    private(set) var settingsWindow: SettingsWindowController?
    let keyboard = KeyboardSettingsStore()
    /// Read at launch, before any text is shown: every window and menu speaks the language chosen for this launch
    private(set) var languages: LanguageSettings?
    /// Started first of all, so the log holds everything the launch does
    let diagnostics = DiagnosticsSettings()
    private var menu: MainMenu?
    private var keyboardObserver: NSObjectProtocol?
    /// Files the Finder asked to open before the window existed: a double click on a .rdp file launches the app
    private var pendingFiles: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        diagnostics.start()
        let languages = LanguageSettings(folder: LanguageFolder(url: LanguageFolder.standard))
        Localization.use(languages.catalog)
        self.languages = languages
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
        if !pendingFiles.isEmpty {
            content.open(pendingFiles)
            pendingFiles = []
        }
    }

    /// .rdp files opened from the Finder or dropped on the Dock icon
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let content = mainWindow?.contentViewController as? ConnectionViewController else {
            pendingFiles += urls
            return
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        content.open(urls)
    }

    /// The menu command: one settings window, made when first asked for
    @objc func showSettings(_ sender: Any?) {
        guard let languages else { return }
        let controller =
            settingsWindow
            ?? SettingsWindowController(keyboard: keyboard, languages: languages, diagnostics: diagnostics)
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
