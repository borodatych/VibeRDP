import XCTest

@testable import VibeRDP

/// The programs of the host as stand-ins in the Dock: their grouping, their icon file and their bundle
final class DockProxiesTests: XCTestCase {
    private func window(_ id: UInt64, exe: String, owner: UInt64 = 0, kind: String = "app", icon: Data? = nil)
        -> [MessagePackValue]
    {
        var create: [(String, MessagePackValue)] = [
            ("type", .string("window.create")), ("id", .uint(id)), ("exe", .string(exe)), ("owner", .uint(owner)),
            ("kind", .string(kind)), ("rect", .array([.int(0), .int(0), .int(10), .int(10)])),
        ]
        create.append(("title", .string("w\(id)")))
        var messages: [MessagePackValue] = [.map(create)]
        if let icon {
            messages.append(.map([("type", .string("window.icon")), ("id", .uint(id)), ("png", .binary(icon))]))
        }
        return messages
    }

    func testWindowsGroupByExecutableTopFirst() {
        var remote = RemoteWindows()
        let messages = window(1, exe: "EXCEL.EXE") + window(2, exe: "notepad.exe", icon: Data([2]))
            + window(3, exe: "EXCEL.EXE", icon: Data([3])) + window(4, exe: "EXCEL.EXE", owner: 1)
            + window(5, exe: "notepad.exe", kind: "popup")
        messages.forEach { _ = remote.apply($0) }
        _ = remote.apply(.map([("type", .string("zorder")), ("ids", .array([3, 2, 1, 4, 5].map { .uint($0) }))]))
        let groups = DockGroup.groups(of: remote)
        XCTAssertEqual(groups.map(\.key), ["excel", "notepad"])
        XCTAssertEqual(groups[0].name, "EXCEL")
        XCTAssertEqual(groups[0].windows, [3, 1], "dialogs belong to their owner")
        XCTAssertEqual(groups[0].icon, Data([3]))
        XCTAssertEqual(groups[1].windows, [2], "popups are not windows of their own")
    }

    func testKeysAreSafeForABundleIdentifier() {
        XCTAssertEqual(DockGroup.key(of: "Visual Studio.exe"), "visual-studio")
        XCTAssertEqual(DockGroup.key(of: "Книга.EXE"), "-----")
        XCTAssertEqual(DockGroup.key(of: ".exe"), "program")
    }

    func testIconFileHoldsThePngTypes() {
        let file = IconFile.icns([256: Data([1, 2]), 128: Data([3]), 48: Data([9])])
        let bytes = [UInt8](file ?? Data())
        XCTAssertEqual(Array(bytes[0 ..< 4]), Array("icns".utf8))
        XCTAssertEqual(Array(bytes[4 ..< 8]), [0, 0, 0, 8 + 9 + 10], "the 48 has no PNG type and stays out")
        XCTAssertEqual(Array(bytes[8 ..< 12]), Array("ic07".utf8))
        XCTAssertEqual(Array(bytes[17 ..< 21]), Array("ic08".utf8))
        XCTAssertNil(IconFile.icns([48: Data([1])]))
    }

    /// The stand-in made from the template the app carries: renamed, with the icon, and a valid signature
    func testBundleIsRenamedAndSigned() throws {
        let template = try XCTUnwrap(
            Bundle.main.sharedSupportURL?.appending(path: DockProxies.templateName), "the app carries the template")
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "excel.app")
        let png = try XCTUnwrap(pngOfOnePixel())
        let icons = DockProxies.iconImages(from: png)
        XCTAssertEqual(Set(icons.keys), [128, 256])
        let group = DockGroup(key: "excel", name: "EXCEL", windows: [1], icon: png)
        try DockProxyBundle.make(from: template, at: destination, group: group, icons: icons)

        let info = try XCTUnwrap(NSDictionary(contentsOf: destination.appending(path: "Contents/Info.plist")))
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "tech.vibebrains.viberdp.proxy.excel")
        XCTAssertEqual(info["CFBundleName"] as? String, "EXCEL")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "Contents/Resources/AppIcon.icns").path))

        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", destination.path]
        try verify.run()
        verify.waitUntilExit()
        XCTAssertEqual(verify.terminationStatus, 0, "the copy is signed again after its Info.plist changed")
    }

    private func pngOfOnePixel() -> Data? {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.systemGreen.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// The path LaunchServices takes: the stand-in starts, its answer comes back to the main thread, and it goes
    /// when the program goes; the answer once came on a queue of LaunchServices and stopped the app
    @MainActor
    func testStandInStartsAndGoes() async throws {
        guard Bundle.main.sharedSupportURL.map({ FileManager.default.fileExists(atPath: $0.appending(path: DockProxies.templateName).path) }) == true
        else { throw XCTSkip("no stand-in template in the host app") }
        let key = "test-\(UUID().uuidString.prefix(8).lowercased())"
        let proxies = DockProxies(onActivate: { _ in }, onQuit: { _ in })
        defer { proxies.invalidate() }
        let group = DockGroup(key: key, name: "TEST", windows: [1], icon: pngOfOnePixel())
        proxies.update([group])
        // The first start of a freshly signed bundle waits for the system to assess it: seconds, more under load
        for _ in 0 ..< 600 where !proxies.isRunning(key) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(proxies.isRunning(key), "the stand-in started")
        let identifier = DockProxies.identifierPrefix + key
        XCTAssertFalse(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty)
        proxies.update([])
        for _ in 0 ..< 100 where !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty, "the stand-in went")
        try? FileManager.default.removeItem(at: DockProxies.folder.appending(path: "\(key).app"))
    }
}
