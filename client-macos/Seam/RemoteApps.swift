import Foundation

/// The programs of the Start menu of the host, from the apps and app.icon messages: section 8 of the specification
struct RemoteApps: Equatable {
    struct App: Equatable {
        /// What launch takes: the root and the path of the shortcut
        let id: String
        let name: String
        /// The folders from the root of the menu, "" for the root itself
        let folder: String
        var icon: Data?
    }

    /// A folder of the menu with its programs and subfolders, both sorted as the host sent them
    struct Folder: Equatable {
        let name: String
        var apps: [App] = []
        var folders: [Folder] = []
    }

    private(set) var apps: [App] = []

    /// Takes a message of the launcher; false for any other message, which is not for this model
    mutating func apply(_ message: MessagePackValue) -> Bool {
        switch message["type"]?.string {
        case "apps":
            let icons = Dictionary(apps.compactMap { app in app.icon.map { (app.id, $0) } }, uniquingKeysWith: { a, _ in a })
            apps = (message["items"]?.array ?? []).compactMap { item in
                guard let id = item["id"]?.string, let name = item["name"]?.string else { return nil }
                return App(id: id, name: name, folder: item["folder"]?.string ?? "", icon: icons[id])
            }
            return true
        case "app.icon":
            guard let id = message["id"]?.string, let png = message["png"]?.binary,
                let index = apps.firstIndex(where: { $0.id == id })
            else { return true }
            var app = apps[index]
            app.icon = png
            apps[index] = app
            return true
        default:
            return false
        }
    }

    /// The menu as a tree: the root folder with the programs at its top level
    var tree: Folder {
        var root = Folder(name: "")
        for app in apps {
            let path = app.folder.split(separator: "/").map(String.init)
            Self.insert(app, at: path[...], into: &root)
        }
        return root
    }

    private static func insert(_ app: App, at path: ArraySlice<String>, into folder: inout Folder) {
        guard let first = path.first else {
            folder.apps.append(app)
            return
        }
        if let index = folder.folders.firstIndex(where: { $0.name == first }) {
            var child = folder.folders[index]
            insert(app, at: path.dropFirst(), into: &child)
            folder.folders[index] = child
        } else {
            var child = Folder(name: first)
            insert(app, at: path.dropFirst(), into: &child)
            folder.folders.append(child)
        }
    }
}
