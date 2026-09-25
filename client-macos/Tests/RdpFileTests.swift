import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import VibeRDP

/// .rdp files as mstsc, Windows App and other tools save them
final class RdpFileTests: XCTestCase {
    /// A file as mstsc saves it: UTF-16 little-endian with a byte order mark, CRLF, secrets in binary settings
    static let mstsc = """
        screen mode id:i:2\r
        desktopwidth:i:1920\r
        full address:s:win11.corp.local\r
        username:s:CORP\\alice\r
        password 51:b:01000000D08C9DDF0115D1118C7A00C04FC297EB\r
        gatewayhostname:s:\r
        prompt for credentials:i:0\r

        """

    func testMstscFileInUtf16() throws {
        var data = Data([0xFF, 0xFE])
        data.append(try XCTUnwrap(Self.mstsc.data(using: .utf16LittleEndian)))
        let file = try XCTUnwrap(RdpFile(data: data))
        XCTAssertEqual(file.address, "win11.corp.local")
        XCTAssertEqual(file.username, "CORP\\alice")
        XCTAssertEqual(file.integer("screen mode id"), 2)
        XCTAssertNil(file.string("gatewayhostname"), "an empty string is no setting")
        XCTAssertNil(file.string("password 51"), "binary settings are left out")

        let profile = try XCTUnwrap(file.profile(named: "Рабочий ПК"))
        XCTAssertEqual(profile.name, "Рабочий ПК")
        XCTAssertEqual(profile.address, "win11.corp.local")
        XCTAssertEqual(profile.username, "CORP\\alice")
    }

    /// Keys ignore case, UTF-8 comes with or without its mark, and a value keeps its own colons
    func testUtf8AndKeyCase() throws {
        let text = "Full Address:s:[fe80::1]:3390\nUserName:s:bob@corp.local\n"
        for prefix in [Data(), Data([0xEF, 0xBB, 0xBF])] {
            let file = try XCTUnwrap(RdpFile(data: prefix + Data(text.utf8)))
            XCTAssertEqual(file.address, "[fe80::1]:3390")
            XCTAssertEqual(file.username, "bob@corp.local")
        }
    }

    /// As in mstsc and FreeRDP: the alternate address wins, and server port wins over the port in the address
    func testAddressPrecedence() throws {
        let both = try XCTUnwrap(
            RdpFile(data: Data("full address:s:old:4000\nalternate full address:s:new\n".utf8)))
        XCTAssertEqual(both.address, "new")

        let port = try XCTUnwrap(RdpFile(data: Data("full address:s:win:4000\nserver port:i:5000\n".utf8)))
        XCTAssertEqual(port.address, "win:5000")

        let standard = try XCTUnwrap(RdpFile(data: Data("full address:s:win:3389\n".utf8)))
        XCTAssertEqual(standard.address, "win", "the default port is left out, as the editor shows it")

        let bareIPv6 = try XCTUnwrap(RdpFile(data: Data("full address:s:fe80::1\nserver port:i:3390\n".utf8)))
        XCTAssertEqual(bareIPv6.address, "[fe80::1]:3390")
    }

    /// A domain setting joins a bare user name, and never one that names its own domain
    func testDomainJoinsTheUserName() throws {
        let joined = try XCTUnwrap(RdpFile(data: Data("full address:s:w\nusername:s:alice\ndomain:s:CORP\n".utf8)))
        XCTAssertEqual(joined.username, "CORP\\alice")
        let own = try XCTUnwrap(RdpFile(data: Data("full address:s:w\nusername:s:a@b\ndomain:s:CORP\n".utf8)))
        XCTAssertEqual(own.username, "a@b")
        let none = try XCTUnwrap(RdpFile(data: Data("full address:s:w\ndomain:s:CORP\n".utf8)))
        XCTAssertEqual(none.username, "")
    }

    /// The gateway of a file, as FreeRDP reads it: used always (1) or outside the local network (2), never otherwise
    func testGatewaySettings() throws {
        let always = try XCTUnwrap(
            RdpFile(
                data: Data(
                    """
                    full address:s:desktop.internal
                    gatewayhostname:s:gw.corp.com:8443
                    gatewayusagemethod:i:1
                    promptcredentialonce:i:0

                    """.utf8)))
        let profile = try XCTUnwrap(always.profile(named: "x"))
        XCTAssertEqual(profile.gatewayAddress, "gw.corp.com:8443")
        XCTAssertEqual(profile.gateway?.port, 8443)
        XCTAssertFalse(profile.gatewayUsesServerCredentials)
        XCTAssertFalse(profile.gatewayBypassLocal)

        let detect = try XCTUnwrap(
            RdpFile(data: Data("full address:s:w\ngatewayhostname:s:gw\ngatewayusagemethod:i:2\n".utf8)))
        XCTAssertEqual(detect.profile(named: "x")?.gatewayAddress, "gw")
        XCTAssertEqual(detect.profile(named: "x")?.gatewayBypassLocal, true)
        XCTAssertEqual(detect.profile(named: "x")?.gatewayUsesServerCredentials, true)

        for method in [0, 3, 4] {
            let off = try XCTUnwrap(
                RdpFile(data: Data("full address:s:w\ngatewayhostname:s:gw\ngatewayusagemethod:i:\(method)\n".utf8)))
            XCTAssertEqual(off.profile(named: "x")?.gatewayAddress, "", "method \(method)")
        }
        let noMethod = try XCTUnwrap(RdpFile(data: Data("full address:s:w\ngatewayhostname:s:gw\n".utf8)))
        XCTAssertEqual(noMethod.profile(named: "x")?.gatewayAddress, "")
    }

    /// A file without settings is no connection file, and one without an address makes no profile
    func testWhatIsNoConnection() throws {
        XCTAssertNil(RdpFile(data: Data()))
        XCTAssertNil(RdpFile(data: Data("just some text\nwith lines\n".utf8)))
        XCTAssertNil(RdpFile(data: Data([0xFF, 0xD8, 0xFF, 0xE0])))
        let noAddress = try XCTUnwrap(RdpFile(data: Data("username:s:alice\n".utf8)))
        XCTAssertNil(noAddress.profile(named: "x"))
        let badAddress = try XCTUnwrap(RdpFile(data: Data("full address:s:two words\n".utf8)))
        XCTAssertNil(badAddress.profile(named: "x"))
    }

    /// The app declares the type of .rdp files and opens them
    /// The declaration is checked rather than looked up: Launch Services knows only apps it registered, and on a Mac
    /// with Windows App its own export of the type wins
    func testAppDeclaresTheDocumentType() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let imported = try XCTUnwrap(info["UTImportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try XCTUnwrap(
            imported.first { $0["UTTypeIdentifier"] as? String == UTType.rdpFile.identifier })
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["rdp"])

        let types = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let contentTypes = types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertTrue(contentTypes.contains(UTType.rdpFile.identifier))
    }
}

/// Files reach the list through the window: added, or found when already there
@MainActor
final class ImportTests: XCTestCase {
    private var suiteName = ""
    private var folder: URL!

    override func setUp() async throws {
        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    func testImportAddsOnceAndReportsBadFiles() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let form = ConnectionViewController(
            trusted: TrustedCertificates(defaults: defaults), keyboard: KeyboardSettingsStore(defaults: defaults),
            profiles: ProfileStore(defaults: defaults, passwords: MemoryPasswordStore()))
        let office = folder.appendingPathComponent("Офис.rdp")
        try Data("full address:s:win.corp:3390\nusername:s:CORP\\alice\n".utf8).write(to: office)
        let broken = folder.appendingPathComponent("заметка.rdp")
        try Data("not a connection".utf8).write(to: broken)

        form.importFiles([office], connecting: false)
        XCTAssertEqual(form.model.store.profiles.map(\.title), ["Офис"])
        XCTAssertEqual(form.model.selectedProfile?.address, "win.corp:3390")
        XCTAssertEqual(form.model.status, Localization.text(.connectionsImported, ["name": "Офис"]))

        form.importFiles([office], connecting: false)
        XCTAssertEqual(form.model.store.profiles.count, 1)
        XCTAssertEqual(form.model.status, Localization.text(.connectionsImportedExisting, ["name": "Офис"]))

        form.importFiles([broken], connecting: false)
        XCTAssertEqual(form.model.store.profiles.count, 1)
        XCTAssertEqual(form.model.status, Localization.text(.connectionsImportFailed, ["file": "заметка.rdp"]))
    }

    func testFileMenuImports() throws {
        let file = try XCTUnwrap(NSApp.mainMenu?.items[1].submenu)
        let item = try XCTUnwrap(
            file.items.first { $0.action == #selector(ConnectionViewController.importConnectionFiles(_:)) })
        XCTAssertEqual(item.keyEquivalent, "o")
        XCTAssertEqual(item.title, Localization.text(.menuFileImport))
    }
}
