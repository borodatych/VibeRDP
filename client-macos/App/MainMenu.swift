import AppKit

/// Menu bar of the app: the application, File and Window menus that every Mac app has
@MainActor
struct MainMenu {
    let bar = NSMenu()
    /// AppKit lists open windows in this menu once it becomes NSApp.windowsMenu
    let windowMenu: NSMenu
    /// Its shortcut is a keyboard setting
    let disconnectItem: NSMenuItem
    /// The desktop in place of the windows of Windows, in a session of that mode; the app sets its target
    let windowsDesktopItem: NSMenuItem
    /// The Start menu of the host and the item of the bar that holds it, filled by StartMenu
    let startMenu: NSMenu
    let startItem = NSMenuItem()

    init(appName: String) {
        let app = ["app": appName]

        let application = NSMenu()
        application.addItem(
            Self.item(.menuAppAbout, app, #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        application.addItem(.separator())
        application.addItem(Self.item(.menuAppSettings, [:], #selector(AppDelegate.showSettings(_:)), key: ","))
        application.addItem(.separator())
        application.addItem(Self.item(.menuAppHide, app, #selector(NSApplication.hide(_:)), key: "h"))
        application.addItem(
            Self.item(
                .menuAppHideOthers, [:], #selector(NSApplication.hideOtherApplications(_:)), key: "h",
                modifiers: [.command, .option]))
        application.addItem(Self.item(.menuAppShowAll, [:], #selector(NSApplication.unhideAllApplications(_:))))
        application.addItem(.separator())
        application.addItem(Self.item(.menuAppQuit, app, #selector(NSApplication.terminate(_:)), key: "q"))

        let file = NSMenu(title: Localization.text(.menuFile))
        file.addItem(
            Self.item(.menuFileImport, [:], #selector(ConnectionViewController.importConnectionFiles(_:)), key: "o"))
        file.addItem(
            Self.item(
                .menuFileImportWindowsApp, [:], #selector(ConnectionViewController.importWindowsAppConnections(_:))))
        file.addItem(.separator())
        disconnectItem = Self.item(.menuFileDisconnect, [:], #selector(ConnectionViewController.disconnect(_:)))
        file.addItem(disconnectItem)
        file.addItem(.separator())
        file.addItem(Self.item(.menuFileClose, [:], #selector(NSWindow.performClose(_:)), key: "w"))

        windowMenu = NSMenu(title: Localization.text(.menuWindow))
        windowMenu.addItem(Self.item(.menuWindowMinimize, [:], #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        // AppKit gives this item the system shortcut itself, fn-F, and replaces any other
        windowMenu.addItem(Self.item(.menuWindowFullScreen, [:], #selector(NSWindow.toggleFullScreen(_:))))
        windowMenu.addItem(.separator())
        windowsDesktopItem = Self.item(
            .menuWindowWindowsDesktop, [:], #selector(ConnectionViewController.toggleWindowsDesktop(_:)))
        windowMenu.addItem(windowsDesktopItem)

        startMenu = NSMenu(title: Localization.text(.menuStart))
        for submenu in [application, file, startMenu, windowMenu] {
            let holder = submenu === startMenu ? startItem : NSMenuItem()
            holder.submenu = submenu
            bar.addItem(holder)
        }
    }

    /// The shortcut of Disconnect follows the keyboard settings; the Mac keeps it while the desktop has the keyboard
    func apply(_ keyboard: KeyboardSettings) {
        let equivalent = keyboard.disconnect?.menuKeyEquivalent
        disconnectItem.keyEquivalent = equivalent?.key ?? ""
        disconnectItem.keyEquivalentModifierMask = equivalent?.mask ?? []
    }

    /// Items without a target go to the responder chain: the key window or the app answers them
    private static func item(
        _ key: TextKey, _ values: [String: String], _ action: Selector, key equivalent: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: Localization.text(key, values), action: action, keyEquivalent: equivalent)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
