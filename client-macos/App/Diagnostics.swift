import AppKit
import Observation
import VibeRDPCore

/// The diagnostics log: the engine and the app write into one file of ~/VibeRDP/logs, a file for each launch,
/// for whoever reads it when a session misbehaves
/// While VibeRDP is in development the log is on by default; the first release turns the default off,
/// and a user who needs the log turns it on in the settings and sends the file or attaches it to an issue
@MainActor
@Observable
final class DiagnosticsSettings {
    /// Development builds keep the log from the first launch; the release sets this to false, roadmap 2.6
    static let enabledByDefault = true
    static let defaultsKey = "diagnosticsLog"
    /// Logs of older launches beyond this many are removed when a new one starts
    static let keptLogs = 10
    static let fileExtension = "log"
    /// Where users report problems, with the log attached
    static let issuesURL = URL(string: "https://github.com/borodatych/VibeRDP/issues/new")!

    /// ~/VibeRDP/logs: beside the languages, where the user finds it without Library
    static var standardFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "VibeRDP/logs", directoryHint: .isDirectory)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let openLog: (URL) -> Bool
    let folder: URL
    /// The file of this launch; nil while the log is off or when its file could not be opened
    private(set) var file: URL?

    /// For the next launch: the engine logs from its start, so a change takes effect after a restart
    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Self.defaultsKey) }
    }

    init(
        folder: URL = DiagnosticsSettings.standardFolder, defaults: UserDefaults = .standard,
        openLog: @escaping (URL) -> Bool = { VRCLogToFile($0.path(percentEncoded: false), .info) == .OK }
    ) {
        self.folder = folder
        self.defaults = defaults
        self.openLog = openLog
        enabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? Self.enabledByDefault
    }

    /// Starts the log of this launch when it is on: a file named by the time of the launch, the oldest beyond the kept
    /// ones removed, and a first line that names the build and the system
    func start(now: Date = Date()) {
        guard enabled else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        removeOldLogs()
        let name = Self.fileName(for: now)
        let url = folder.appending(path: name)
        guard openLog(url) else { return }
        file = url
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Diagnostics.info("app", "VibeRDP \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func reportProblem() {
        NSWorkspace.shared.open(Self.issuesURL)
    }

    /// viberdp-2026-09-25-17-40-05.log: the names sort by time, so the newest is last in the Finder
    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return "viberdp-\(formatter.string(from: date)).\(fileExtension)"
    }

    /// Leaves room for the new file among the kept ones
    private func removeOldLogs() {
        let logs =
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == Self.fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in logs.dropLast(Self.keptLogs - 1) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}

/// Lines of the app in the diagnostics log: English, for whoever reads the log, not interface text
enum Diagnostics {
    static func info(_ category: String, _ message: String) {
        VRCLog(.info, category, message)
    }

    static func warning(_ category: String, _ message: String) {
        VRCLog(.warning, category, message)
    }
}
