import AppKit

/// Lifecycle of the app: builds the menu bar and the main window once launching finishes
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindow: NSWindow?
    /// Keeps where the user leaves the main window, for the next launch
    private var mainWindowFrame: WindowFrameKeeper?
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

    /// How long after the main window shows its place goes to the log, so a move by the system is caught
    static let placementCheckDelay: TimeInterval = 1

    /// XCTest runs its tests inside the app and names its configuration to the process through this variable
    static let testConfigurationVariable = "XCTestConfigurationFilePath"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A test run launches the app again and again: its logs would push the user's own out of the kept ones
        if ProcessInfo.processInfo.environment[Self.testConfigurationVariable] == nil {
            diagnostics.start()
        }
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
        let content = ConnectionViewController(
            trusted: TrustedCertificates(), keyboard: keyboard, profiles: profiles,
            sessionFrameName: SessionWindowController.frameName)
        // The switch works from any window of the session, and the windows of Windows are not in a responder chain
        // that reaches the list of connections
        menu.windowsDesktopItem.target = content
        let window = MainWindow.make(title: Self.mainWindowTitle, content: content)
        mainWindowFrame = WindowFrameKeeper(
            window: window, name: MainWindow.frameName, fallback: WindowPlacement.primaryScreen)
        window.makeKeyAndOrderFront(nil)
        // The system may move a window after it shows, as onto another display: the log shows where it stays
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.placementCheckDelay))
            self?.mainWindowFrame?.holdOpeningPlace()
            self?.mainWindowFrame?.logPlace("shown")
            self?.mainWindowFrame?.endOpening()
        }
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

    /// The app became active after launch: the system may have moved the main window by now
    func applicationDidBecomeActive(_ notification: Notification) {
        mainWindowFrame?.holdOpeningPlace()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Product name from Info.plist: a name, so no language translates it
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    }

    /// Product version from Info.plist, empty when it has none
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// The name and the version over the main window: a new build is told from the last one at a glance
    static var mainWindowTitle: String {
        appVersion.isEmpty ? appName : "\(appName) \(appVersion)"
    }
}
