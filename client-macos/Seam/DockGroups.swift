import Foundation

/// One program of the host as the Dock shows it: the windows of one executable, top first
struct DockGroup: Equatable {
    /// The part of the bundle identifier of its stand-in: the executable in lowercase letters, digits and dashes
    let key: String
    /// The name under the icon: the executable without its extension, "EXCEL" for EXCEL.EXE
    let name: String
    let windows: [UInt64]
    /// PNG of the topmost window that has one; nil until the helper sends one
    let icon: Data?

    /// The windows of the host grouped by their executable: windows of their own only,
    /// since dialogs, menus and tooltips belong to the program of their owner
    static func groups(of remote: RemoteWindows) -> [DockGroup] {
        var order: [String] = []
        var members: [String: [RemoteWindow]] = [:]
        for window in remote.ordered where window.kind == .app && window.owner == 0 && !window.exe.isEmpty {
            let key = Self.key(of: window.exe)
            if members[key] == nil {
                order.append(key)
            }
            members[key, default: []].append(window)
        }
        return order.map { key in
            let windows = members[key] ?? []
            return DockGroup(
                key: key, name: Self.name(of: windows[0].exe), windows: windows.map(\.id),
                icon: windows.lazy.compactMap(\.icon).first)
        }
    }

    static func key(of exe: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let key = String(name(of: exe).lowercased().map { allowed.contains($0) ? $0 : "-" })
        return key.isEmpty ? "program" : key
    }

    static func name(of exe: String) -> String {
        exe.lowercased().hasSuffix(".exe") ? String(exe.dropLast(4)) : exe
    }
}
