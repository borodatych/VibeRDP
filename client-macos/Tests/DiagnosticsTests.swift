import XCTest

@testable import VibeRDP

/// The diagnostics log settings, with a folder of their own and the engine log left alone
@MainActor
final class DiagnosticsTests: XCTestCase {
    private var suiteName = ""
    private var folder: URL!

    override func setUp() async throws {
        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        folder = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    /// The default holds until the user decides, and the decision is kept for the next launch
    func testDefaultAndChoice() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(
            DiagnosticsSettings(folder: folder, defaults: defaults, openLog: { _ in true }).enabled,
            DiagnosticsSettings.enabledByDefault)
        let settings = DiagnosticsSettings(folder: folder, defaults: defaults, openLog: { _ in true })
        settings.enabled = false
        XCTAssertFalse(DiagnosticsSettings(folder: folder, defaults: defaults, openLog: { _ in true }).enabled)
    }

    /// A launch opens a file named by its time and leaves the newest older logs, the rest go
    func testStartOpensAFileAndKeepsTheNewestLogs() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: DiagnosticsSettings.defaultsKey)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = (0..<DiagnosticsSettings.keptLogs + 2).map {
            DiagnosticsSettings.fileName(for: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + $0)))
        }
        for name in old + ["notes.txt"] {
            try Data().write(to: folder.appending(path: name))
        }
        var opened: [URL] = []
        let settings = DiagnosticsSettings(
            folder: folder, defaults: defaults,
            openLog: {
                opened.append($0)
                return true
            })
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        settings.start(now: now)

        let name = DiagnosticsSettings.fileName(for: now)
        XCTAssertEqual(opened.map(\.lastPathComponent), [name])
        XCTAssertEqual(settings.file?.lastPathComponent, name)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        XCTAssertEqual(Set(left), Set(old.suffix(DiagnosticsSettings.keptLogs - 1) + ["notes.txt"]))
    }

    /// A log that is off opens nothing
    func testOffOpensNothing() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(false, forKey: DiagnosticsSettings.defaultsKey)
        var opened = 0
        let settings = DiagnosticsSettings(
            folder: folder, defaults: defaults,
            openLog: { _ in
                opened += 1
                return true
            })
        settings.start()
        XCTAssertEqual(opened, 0)
        XCTAssertNil(settings.file)
    }

    func testFileNamesSortByTime() {
        let earlier = DiagnosticsSettings.fileName(for: Date(timeIntervalSince1970: 1_700_000_000))
        let later = DiagnosticsSettings.fileName(for: Date(timeIntervalSince1970: 1_700_000_061))
        XCTAssertTrue(earlier.hasPrefix("viberdp-") && earlier.hasSuffix(".log"))
        XCTAssertLessThan(earlier, later)
    }
}
