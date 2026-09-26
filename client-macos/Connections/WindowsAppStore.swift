import AppKit
import SQLite3

/// The connections Windows App keeps on this Mac, read so they can join the list without retyping
///
/// Windows App keeps them in a Core Data store in its container: a bookmark holds the settings as a whole .rdp file,
/// its name and host beside it, and links to a credential with the user name and to a gateway
/// The passwords are in the keychain of Windows App and stay there: the user types each once, VibeRDP keeps it
/// The store is written with a write-ahead log: it is read from a copy with the log, never where Windows App uses it
struct WindowsAppStore {
    static let bundleIdentifier = "com.microsoft.rdc.macos"
    static let defaultDatabase = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Containers/\(bundleIdentifier)/Data/Library/Application Support")
        .appending(path: "\(bundleIdentifier)/com.microsoft.rdc.application-data.sqlite")
    /// The files SQLite keeps beside a store with a write-ahead log: without them the copy misses recent changes
    static let companionSuffixes = ["-wal", "-shm"]

    enum ReadError: Error, Equatable {
        /// No store, or macOS did not let VibeRDP read it
        case unreadable
        /// Tables or columns this reader does not know: a version of Windows App stores its connections otherwise
        case unknownSchema
    }

    /// One bookmark as the store keeps it
    struct Bookmark: Equatable {
        var friendlyName: String?
        var hostname: String?
        var rdp: String?
        var username: String?
        var gatewayHostname: String?
        var gatewayUsername: String?
        /// The gateway signs in with the credential of the computer
        var gatewaySharesCredential: Bool
    }

    /// The tables and columns the query reads: checked first, so a new schema gives a clear refusal
    static let requiredColumns: [String: [String]] = [
        "ZBOOKMARKENTITY": ["ZFRIENDLYNAME", "ZHOSTNAME", "ZRDPSTRING", "ZCREDENTIAL", "ZGATEWAY"],
        "ZCREDENTIALENTITY": ["Z_PK", "ZUSERNAME"],
        "ZGATEWAYENTITY": ["Z_PK", "ZHOSTNAME", "ZCREDENTIAL"],
    ]

    static let query = """
        SELECT b.ZFRIENDLYNAME, b.ZHOSTNAME, b.ZRDPSTRING, c.ZUSERNAME, g.ZHOSTNAME, gc.ZUSERNAME,
               g.ZCREDENTIAL IS NULL OR g.ZCREDENTIAL = b.ZCREDENTIAL
        FROM ZBOOKMARKENTITY b
        LEFT JOIN ZCREDENTIALENTITY c ON c.Z_PK = b.ZCREDENTIAL
        LEFT JOIN ZGATEWAYENTITY g ON g.Z_PK = b.ZGATEWAY
        LEFT JOIN ZCREDENTIALENTITY gc ON gc.Z_PK = g.ZCREDENTIAL
        ORDER BY b.Z_PK
        """

    let database: URL

    init(database: URL = Self.defaultDatabase) {
        self.database = database
    }

    /// Windows App is installed: asking the Launch Services database touches nothing of its data
    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// The profiles of all bookmarks; one without an address is left out
    func profiles() throws -> [ConnectionProfile] {
        try bookmarks().compactMap(Self.profile)
    }

    func bookmarks() throws -> [Bookmark] {
        let copy = FileManager.default.temporaryDirectory.appending(path: "viberdp-windows-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        let file = copy.appending(path: database.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: database, to: file)
        } catch {
            throw ReadError.unreadable
        }
        for suffix in Self.companionSuffixes {
            let source = URL(fileURLWithPath: database.path(percentEncoded: false) + suffix)
            let target = URL(fileURLWithPath: file.path(percentEncoded: false) + suffix)
            try? FileManager.default.copyItem(at: source, to: target)
        }

        // The copy is ours: opening it for writing lets SQLite fold the log in
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path(percentEncoded: false), &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
            let handle
        else {
            sqlite3_close(handle)
            throw ReadError.unreadable
        }
        defer { sqlite3_close(handle) }
        for (table, columns) in Self.requiredColumns
        where !Set(columns).isSubset(of: try Self.columns(of: table, in: handle)) {
            throw ReadError.unknownSchema
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, Self.query, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw ReadError.unknownSchema
        }
        defer { sqlite3_finalize(statement) }
        var bookmarks: [Bookmark] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            bookmarks.append(
                Bookmark(
                    friendlyName: Self.text(statement, 0), hostname: Self.text(statement, 1),
                    rdp: Self.text(statement, 2), username: Self.text(statement, 3),
                    gatewayHostname: Self.text(statement, 4), gatewayUsername: Self.text(statement, 5),
                    gatewaySharesCredential: sqlite3_column_int(statement, 6) != 0))
        }
        return bookmarks
    }

    /// The profile of a bookmark: the settings of its .rdp, with the name, host, user and gateway of the store on top
    static func profile(_ bookmark: Bookmark) -> ConnectionProfile? {
        let rdp = bookmark.rdp.flatMap { RdpFile(data: Data($0.utf8)) }
        guard let address = rdp?.address ?? bookmark.hostname.flatMap({ ServerAddress($0) == nil ? nil : $0 })
        else { return nil }
        // A gateway of the store brings its own credential or shares the one of the computer; one of the .rdp says so
        // with promptcredentialonce, as an imported file does
        let sharesCredential =
            bookmark.gatewayHostname != nil
            ? bookmark.gatewaySharesCredential : rdp?.integer("promptcredentialonce").map { $0 != 0 } ?? true
        return ConnectionProfile(
            name: bookmark.friendlyName ?? "", address: address, username: bookmark.username ?? rdp?.username ?? "",
            gatewayAddress: bookmark.gatewayHostname ?? rdp?.gatewayAddress ?? "",
            gatewayUsesServerCredentials: sharesCredential,
            gatewayUsername: sharesCredential ? "" : bookmark.gatewayUsername ?? rdp?.string("gatewayusername") ?? "",
            gatewayBypassLocal: rdp?.integer("gatewayusagemethod") == 2, displayMode: rdp?.displayMode ?? .window,
            fixedSize: rdp?.desktopSize ?? .standard, audio: rdp?.audio ?? .local)
    }

    private static func columns(of table: String, in handle: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw ReadError.unknownSchema
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1) {
                names.insert(name)
            }
        }
        return names
    }

    /// A text column, nil when it is NULL or empty
    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        let value = String(cString: bytes)
        return value.isEmpty ? nil : value
    }
}
