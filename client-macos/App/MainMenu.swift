import AppKit

/// Menu bar of the app: the application, File and Window menus that every Mac app has
@MainActor
struct MainMenu {
    let bar = NSMenu()
    /// AppKit lists open windows in this menu once it becomes NSApp.windowsMenu
    let windowMenu: NSMenu

    init(appName: String) {
        let app = ["app": appName]

        let application = NSMenu()
        application.addItem(
            Self.item(.menuAppAbout, app, #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
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
        // No shortcut: the Command combinations are to reach the remote desktop, and task 1.4 lays them out
        file.addItem(Self.item(.menuFileDisconnect, [:], #selector(ConnectionViewController.disconnect(_:))))
        file.addItem(.separator())
        file.addItem(Self.item(.menuFileClose, [:], #selector(NSWindow.performClose(_:)), key: "w"))

        windowMenu = NSMenu(title: Localization.text(.menuWindow))
        windowMenu.addItem(Self.item(.menuWindowMinimize, [:], #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        // AppKit gives this item the system shortcut itself, fn-F, and replaces any other
        windowMenu.addItem(Self.item(.menuWindowFullScreen, [:], #selector(NSWindow.toggleFullScreen(_:))))

        for submenu in [application, file, windowMenu] {
            let holder = NSMenuItem()
            holder.submenu = submenu
            bar.addItem(holder)
        }
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
