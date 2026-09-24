/// Where to connect, as the user typed it: a host and an optional port
struct ServerAddress: Equatable, Sendable {
    let host: String
    /// nil keeps the default RDP port
    let port: UInt16?

    /// Accepts host, host:port, [IPv6] and [IPv6]:port
    /// A bare IPv6 address has colons of its own, so it never carries a port
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        let host: Substring
        let portText: Substring?
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            host = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty {
                portText = nil
            } else {
                guard rest.hasPrefix(":") else { return nil }
                portText = rest.dropFirst()
            }
        } else if trimmed.filter({ $0 == ":" }).count == 1, let colon = trimmed.firstIndex(of: ":") {
            host = trimmed[..<colon]
            portText = trimmed[trimmed.index(after: colon)...]
        } else {
            host = trimmed[...]
            portText = nil
        }

        guard !host.isEmpty else { return nil }
        if let portText {
            guard let port = UInt16(portText), port > 0 else { return nil }
            self.port = port
        } else {
            self.port = nil
        }
        self.host = String(host)
    }
}
