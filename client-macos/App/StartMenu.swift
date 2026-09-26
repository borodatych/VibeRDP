import AppKit

/// The Start menu of the host in the menu bar of the Mac, in the Seam mode: folders as submenus, programs as items
/// Choosing a program starts it on the host, and its windows come as any other
@MainActor
final class StartMenu: NSObject, NSMenuDelegate {
    /// The side of the icons in the menu, in points
    static let iconSide: CGFloat = 16

    private let menu: NSMenu
    private let holder: NSMenuItem
    private var apps = RemoteApps()
    var onLaunch: ((String) -> Void)?

    /// The menu and the item of the menu bar that holds it; hidden until a session shows the programs
    init(menu: NSMenu, holder: NSMenuItem) {
        self.menu = menu
        self.holder = holder
        super.init()
        menu.delegate = self
        holder.isHidden = true
    }

    /// The programs of a session that has them; nil hides the menu
    func show(_ apps: RemoteApps?) {
        self.apps = apps ?? RemoteApps()
        holder.isHidden = apps == nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()
        let root = apps.tree
        if root.apps.isEmpty && root.folders.isEmpty {
            let empty = NSMenuItem(title: Localization.text(.menuStartEmpty), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        fill(menu, with: root)
    }

    private func fill(_ menu: NSMenu, with folder: RemoteApps.Folder) {
        for child in folder.folders {
            let item = NSMenuItem(title: child.name, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let submenu = NSMenu(title: child.name)
            fill(submenu, with: child)
            item.submenu = submenu
            menu.addItem(item)
        }
        for app in folder.apps {
            let item = NSMenuItem(title: app.name, action: #selector(launch(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.id
            if let png = app.icon, let image = NSImage(data: png) {
                image.size = NSSize(width: Self.iconSide, height: Self.iconSide)
                item.image = image
            }
            menu.addItem(item)
        }
    }

    @objc private func launch(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            onLaunch?(id)
        }
    }
}
