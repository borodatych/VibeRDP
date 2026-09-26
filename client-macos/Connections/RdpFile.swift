import Foundation
import UniformTypeIdentifiers

/// A Remote Desktop connection file as mstsc and Windows App write it: one `key:type:value` setting a line,
/// the type `s` for a string, `i` for an integer and `b` for binary data
/// The rules follow the parser of FreeRDP, client/common/file.c: keys ignore case, UTF-16 comes with a byte order mark,
/// `alternate full address` wins over `full address`, and `server port` over the port inside the address
struct RdpFile: Equatable {
    private(set) var strings: [String: String] = [:]
    private(set) var integers: [String: Int] = [:]

    /// nil for data that is no text or has no setting at all
    init?(data: Data) {
        guard let text = Self.text(of: data) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[2].trimmingCharacters(in: .whitespaces)
            switch parts[1].trimmingCharacters(in: .whitespaces).lowercased() {
            case "s": strings[key] = value
            case "i": integers[key] = Int(value)
            default: break  // Binary settings hold secrets of the Windows user who saved them: none of them apply here
            }
        }
        guard !strings.isEmpty || !integers.isEmpty else { return nil }
    }

    /// mstsc saves UTF-16 little-endian with a byte order mark; other tools save UTF-8, with or without one
    static func text(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }

    /// A string setting, nil when missing or empty
    func string(_ key: String) -> String? {
        strings[key.lowercased()].flatMap { $0.isEmpty ? nil : $0 }
    }

    func integer(_ key: String) -> Int? {
        integers[key.lowercased()]
    }

    /// Where the file connects, in the form the profile keeps: host, host:port or [IPv6]:port
    var address: String? {
        guard let written = string("alternate full address") ?? string("full address"),
            let parsed = ServerAddress(written)
        else { return nil }
        let port = integer("server port").flatMap { UInt16(exactly: $0) }.flatMap { $0 > 0 ? $0 : nil } ?? parsed.port
        let host = parsed.host.contains(":") ? "[\(parsed.host)]" : parsed.host
        guard let port, port != ServerAddress.defaultPort else { return host }
        return "\(host):\(port)"
    }

    /// DOMAIN\user: a separate domain setting joins the user name unless the name carries its own
    var username: String {
        let user = string("username") ?? ""
        guard !user.isEmpty, let domain = string("domain"), !user.contains("\\"), !user.contains("@") else {
            return user
        }
        return "\(domain)\\\(user)"
    }

    /// The gateway the file goes through: the host when `gatewayusagemethod` says always (1) or outside
    /// the local network (2); FreeRDP treats the other methods as a direct connection, and so does the profile
    var gatewayAddress: String {
        guard let host = string("gatewayhostname"), let method = integer("gatewayusagemethod"), [1, 2].contains(method)
        else { return "" }
        return host
    }

    /// The profile the file describes, named after the file; nil without an address
    /// `promptcredentialonce:i:0` gives the gateway credentials of its own; without the setting the gateway
    /// takes those of the computer, as a new profile does
    func profile(named name: String) -> ConnectionProfile? {
        guard let address else { return nil }
        return ConnectionProfile(
            name: name, address: address, username: username, gatewayAddress: gatewayAddress,
            gatewayUsesServerCredentials: integer("promptcredentialonce").map { $0 != 0 } ?? true,
            gatewayBypassLocal: integer("gatewayusagemethod") == 2, displayMode: displayMode,
            fixedSize: desktopSize ?? .standard)
    }

    /// screen mode id 2 is full screen; a desktop size with dynamic resolution off keeps that size;
    /// anything else follows the window
    var displayMode: ProfileDisplayMode {
        if integer("screen mode id") == 2 {
            return .fullScreen
        }
        return integer("dynamic resolution") == 0 && desktopSize != nil ? .fixed : .window
    }

    /// desktopwidth and desktopheight, within the limits of the protocol; nil unless the file names both
    var desktopSize: DesktopSize? {
        guard let width = integer("desktopwidth"), let height = integer("desktopheight") else { return nil }
        return DesktopSize(width: width, height: height).clamped
    }
}

extension UTType {
    /// The type Windows App exports for .rdp files; the app imports it, so it knows the type without Windows App
    static let rdpFile = UTType(importedAs: "com.microsoft.uti.rdpfile", conformingTo: .data)
}
