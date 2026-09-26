import AppKit
import SQLite3
import XCTest

@testable import VibeRDP

/// The store of Windows App, as a sample with the tables and columns of Windows App 11.4.1
/// The sample is written with a write-ahead log and stays open while it is read, as Windows App keeps its store
@MainActor
final class WindowsAppStoreTests: XCTestCase {
    private var folder: URL!
    private var database: URL!
    private var writer: OpaquePointer?

    static let schema = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE ZCREDENTIALENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
            ZNILPASSWORD INTEGER, ZFRIENDLYNAME VARCHAR, ZID VARCHAR, ZUSERNAME VARCHAR);
        CREATE TABLE ZGATEWAYENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZCREDENTIAL INTEGER,
            ZFRIENDLYNAME VARCHAR, ZHOSTNAME VARCHAR, ZID VARCHAR);
        CREATE TABLE ZBOOKMARKENTITY (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZADMINMODE INTEGER,
            ZBOOKMARKFOLDER INTEGER, ZCREDENTIAL INTEGER, ZGATEWAY INTEGER, ZCREATIONSOURCEENUM VARCHAR,
            ZFRIENDLYNAME VARCHAR, ZHOSTNAME VARCHAR, ZID VARCHAR, ZRDPSTRING VARCHAR, ZTHUMBNAILIMAGE BLOB);
        """

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "viberdp-windows-app-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        database = folder.appending(path: "com.microsoft.rdc.application-data.sqlite")
        XCTAssertEqual(sqlite3_open(database.path(percentEncoded: false), &writer), SQLITE_OK)
        try execute(Self.schema)
    }

    override func tearDown() async throws {
        sqlite3_close(writer)
        try? FileManager.default.removeItem(at: folder)
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(writer, sql, nil, nil, &error)
        let message = error.map { String(cString: $0) } ?? ""
        sqlite3_free(error)
        XCTAssertEqual(result, SQLITE_OK, message)
    }

    /// Windows App writes the .rdp of a bookmark with CR line ends
    private static func rdp(_ lines: [String]) -> String {
        lines.joined(separator: "\r")
    }

    /// Bookmarks come with their names, users and gateways, and the rows still in the log are read too
    func testBookmarksBecomeProfiles() throws {
        let office = Self.rdp([
            "full address:s:win.corp:3390", "gatewayhostname:s:rdg.corp", "gatewayusagemethod:i:2",
            "promptcredentialonce:i:0", "screen mode id:i:2",
        ])
        let lab = Self.rdp(["full address:s:lab.local", "username:s:ignored"])
        try execute(
            """
            INSERT INTO ZCREDENTIALENTITY (Z_PK, ZUSERNAME) VALUES (1, 'CORP\\alice'), (2, 'gw\\bob');
            INSERT INTO ZGATEWAYENTITY (Z_PK, ZHOSTNAME, ZCREDENTIAL) VALUES (1, 'rdg.corp:443', 2);
            INSERT INTO ZBOOKMARKENTITY (Z_PK, ZFRIENDLYNAME, ZHOSTNAME, ZRDPSTRING, ZCREDENTIAL, ZGATEWAY)
                VALUES (1, 'Офис', 'win.corp:3390', '\(office)', 1, 1),
                       (2, '', 'lab.local', '\(lab)', 1, NULL),
                       (3, NULL, 'bare.host', NULL, NULL, NULL),
                       (4, 'Без адреса', '', 'screen mode id:i:2', NULL, NULL);
            """)
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path(percentEncoded: false) + "-wal"))

        let profiles = try WindowsAppStore(database: database).profiles()
        XCTAssertEqual(profiles.map(\.address), ["win.corp:3390", "lab.local", "bare.host"])

        let first = profiles[0]
        XCTAssertEqual(first.name, "Офис")
        XCTAssertEqual(first.username, "CORP\\alice")
        XCTAssertEqual(first.gatewayAddress, "rdg.corp:443")
        XCTAssertFalse(first.gatewayUsesServerCredentials)
        XCTAssertEqual(first.gatewayUsername, "gw\\bob")
        XCTAssertTrue(first.gatewayBypassLocal)

        // The user of the store wins over the one of the .rdp; an empty name leaves the title to the address
        XCTAssertEqual(profiles[1].username, "CORP\\alice")
        XCTAssertEqual(profiles[1].name, "")
        XCTAssertEqual(profiles[1].gatewayAddress, "")
        XCTAssertEqual(profiles[2].username, "")
    }

    /// A gateway that shares the credential of the computer takes no user name of its own
    func testGatewaySharingTheCredential() throws {
        try execute(
            """
            INSERT INTO ZCREDENTIALENTITY (Z_PK, ZUSERNAME) VALUES (1, 'alice');
            INSERT INTO ZGATEWAYENTITY (Z_PK, ZHOSTNAME, ZCREDENTIAL) VALUES (1, 'rdg.corp', 1);
            INSERT INTO ZBOOKMARKENTITY (Z_PK, ZHOSTNAME, ZCREDENTIAL, ZGATEWAY) VALUES (1, 'pc.corp', 1, 1);
            """)
        let profile = try XCTUnwrap(WindowsAppStore(database: database).profiles().first)
        XCTAssertEqual(profile.gatewayAddress, "rdg.corp")
        XCTAssertTrue(profile.gatewayUsesServerCredentials)
        XCTAssertEqual(profile.gatewayUsername, "")
    }

    /// No store, a store of another schema: refusals the window can name, and the store itself stays untouched
    func testRefusals() throws {
        let missing = WindowsAppStore(database: folder.appending(path: "missing.sqlite"))
        XCTAssertThrowsError(try missing.profiles()) { XCTAssertEqual($0 as? WindowsAppStore.ReadError, .unreadable) }

        try execute("ALTER TABLE ZBOOKMARKENTITY RENAME COLUMN ZRDPSTRING TO ZRDPTEXT;")
        XCTAssertThrowsError(try WindowsAppStore(database: database).profiles()) {
            XCTAssertEqual($0 as? WindowsAppStore.ReadError, .unknownSchema)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        XCTAssertEqual(
            Set(leftovers),
            [
                "com.microsoft.rdc.application-data.sqlite",
                "com.microsoft.rdc.application-data.sqlite-wal",
                "com.microsoft.rdc.application-data.sqlite-shm",
            ])
    }

    /// The window adds the profiles once and reports the count; a second import finds them all in the list
    func testWindowImportsOnce() throws {
        try execute(
            """
            INSERT INTO ZBOOKMARKENTITY (Z_PK, ZFRIENDLYNAME, ZHOSTNAME) VALUES (1, 'Офис', 'win.corp'), (2, NULL, 'lab');
            """)
        let suite = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let form = ConnectionViewController(
            trusted: TrustedCertificates(defaults: defaults), keyboard: KeyboardSettingsStore(defaults: defaults),
            profiles: ProfileStore(defaults: defaults, passwords: MemoryPasswordStore()), sessionFrameName: nil)
        let store = WindowsAppStore(database: database)

        form.importWindowsApp(from: store)
        XCTAssertEqual(form.model.store.profiles.map(\.address), ["win.corp", "lab"])
        XCTAssertEqual(
            form.model.status, Localization.text(.connectionsWindowsAppImported, ["added": "2", "existing": "0"]))

        form.importWindowsApp(from: store)
        XCTAssertEqual(form.model.store.profiles.count, 2)
        XCTAssertEqual(
            form.model.status, Localization.text(.connectionsWindowsAppImported, ["added": "0", "existing": "2"]))
    }

    func testFileMenuImportsFromWindowsApp() throws {
        let file = try XCTUnwrap(NSApp.mainMenu?.items[1].submenu)
        let item = try XCTUnwrap(
            file.items.first { $0.action == #selector(ConnectionViewController.importWindowsAppConnections(_:)) })
        XCTAssertEqual(item.title, Localization.text(.menuFileImportWindowsApp))
    }
}
