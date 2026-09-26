import XCTest

@testable import VibeRDP

/// Why the windows of Windows do or do not show, from the state of the channel; and the logs zipped to send
@MainActor
final class SeamDiagnosisTests: XCTestCase {
    func testEveryStateHasItsExplanation() {
        XCTAssertEqual(SeamDiagnosis.of(.ready(agent: "h", capabilities: ["windows"])), .working(agent: "h"))
        XCTAssertEqual(SeamDiagnosis.of(.ready(agent: "h", capabilities: ["icons"])), .noWindows(agent: "h"))
        XCTAssertEqual(SeamDiagnosis.of(.greeting), .waiting)
        XCTAssertEqual(SeamDiagnosis.of(.silent), .noHelper)
        XCTAssertEqual(SeamDiagnosis.of(.closed), .noHelper)
        XCTAssertEqual(SeamDiagnosis.of(.incompatible(version: 2)), .otherVersion(2))
        XCTAssertEqual(SeamDiagnosis.of(.lost), .lost)
    }

    func testNoHelperNamesEveryCauseAndTheRefusalComesFirst() {
        let advice = SeamDiagnosis.noHelper.advice(remoteAppRefused: true).map(\.key)
        XCTAssertEqual(
            advice,
            [.seamDiagnosisRemoteAppRefused, .seamDiagnosisNotInstalled, .seamDiagnosisAppLocker, .seamDiagnosisNotStarted])
        let version = SeamDiagnosis.otherVersion(2).advice(remoteAppRefused: false)
        XCTAssertEqual(version.first?.values, ["theirs": "2", "ours": "1"])
        XCTAssertFalse(Localization.text(version[0].key, version[0].values).contains("{"))
    }

    func testLogsZipWithTheirFolder() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appending(path: "logs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("line".utf8).write(to: folder.appending(path: "viberdp-2026-09-26-20-00-00.log"))
        let settings = DiagnosticsSettings(folder: folder, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let archive = base.appending(path: "logs.zip")
        try settings.exportLogs(to: archive)

        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        list.arguments = ["-l", archive.path]
        let output = Pipe()
        list.standardOutput = output
        try list.run()
        list.waitUntilExit()
        let listing = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(list.terminationStatus, 0)
        XCTAssertTrue(listing.contains("logs/viberdp-2026-09-26-20-00-00.log"), listing)
    }
}
