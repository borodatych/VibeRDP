import AppKit
import Observation

/// A language file of the folder: the code from its name, the name of the language in itself, and its strings
struct LanguageFile: Equatable, Sendable {
    let code: String
    let name: String
    let strings: [String: String]
}

/// The folder of languages the user sees and edits: one JSON file per language, named by its code
/// The base language is compiled in and needs no file; a file of its code corrects the compiled strings
struct LanguageFolder {
    static let baseCode = "ru"
    /// Keys starting with it describe the file, as $name does, and never reach the interface
    static let servicePrefix = "$"
    static let nameKey = "$name"
    static let fileExtension = "json"
    /// Languages the app lays into the folder, and the commented sample next to them
    static let seededLanguages = ["en"]
    static let sampleFile = "example.jsonc"

    /// ~/VibeRDP/lang: beside the user's own folders, not hidden in Application Support
    static var standard: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("VibeRDP/lang", isDirectory: true)
    }

    let url: URL

    /// Lays the languages of the app and the sample into the folder, each only when its file is missing:
    /// a file the user changed stays as it is, and a file the user deleted comes back
    /// The base language is not laid out: a copy of it would freeze today's strings over every later fix
    func seed(from bundle: Bundle) {
        let manager = FileManager.default
        guard (try? manager.createDirectory(at: url, withIntermediateDirectories: true)) != nil else { return }
        let names = Self.seededLanguages.map { "\($0).\(Self.fileExtension)" } + [Self.sampleFile]
        for name in names {
            let target = url.appendingPathComponent(name)
            guard !manager.fileExists(atPath: target.path),
                let source = bundle.url(forResource: name, withExtension: nil, subdirectory: "lang")
            else { continue }
            try? manager.copyItem(at: source, to: target)
        }
    }

    /// The languages in the folder; a file that does not read as a flat JSON object of strings is left out
    func read() -> [LanguageFile] {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == Self.fileExtension }.compactMap(Self.language(at:))
            .sorted { $0.code < $1.code }
    }

    /// Writes the compiled base strings to a file of the base code, for the user to correct them
    /// An existing file is kept: it already holds the user's corrections
    func writeBaseFile() throws -> URL {
        let target = url.appendingPathComponent("\(Self.baseCode).\(Self.fileExtension)")
        guard !FileManager.default.fileExists(atPath: target.path) else { return target }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var strings = Dictionary(uniqueKeysWithValues: TextKey.allCases.map { ($0.rawValue, $0.baseText) })
        strings[Self.nameKey] = TextKey.languageBaseName.baseText
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(strings).write(to: target, options: .atomic)
        return target
    }

    static func language(at file: URL) -> LanguageFile? {
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let strings = object.compactMapValues { $0 as? String }
        let code = file.deletingPathExtension().lastPathComponent
        // A loop rather than Dictionary.filter: Xcode 26.6 specializes that one with a typed-throws path,
        // a call into a runtime newer than macOS 14
        var interface: [String: String] = [:]
        for (key, value) in strings where !key.hasPrefix(servicePrefix) {
            interface[key] = value
        }
        return LanguageFile(code: code, name: strings[nameKey] ?? code, strings: interface)
    }
}

/// Which language a launch speaks, and the catalog it takes
enum LanguageChoice {
    /// The saved choice when its file is still there, else the base: the interface speaks Russian until the user
    /// picks another language, whatever the language of the system
    static func resolve(saved: String?, available: Set<String>) -> String {
        guard let saved, saved == LanguageFolder.baseCode || available.contains(saved) else {
            return LanguageFolder.baseCode
        }
        return saved
    }

    /// The strings of the language over the corrections of the base file: a key the language leaves out
    /// shows the corrected base string, and one the base file leaves out the compiled one
    static func catalog(files: [LanguageFile], code: String) -> [String: String] {
        let base = files.first { $0.code == LanguageFolder.baseCode }?.strings ?? [:]
        guard code != LanguageFolder.baseCode, let chosen = files.first(where: { $0.code == code }) else {
            return base
        }
        return base.merging(chosen.strings) { _, translated in translated }
    }
}

/// The language settings: the languages of this launch and the choice kept for the next one
/// The folder is read once, at startup, so a changed choice speaks after a restart
@MainActor
@Observable
final class LanguageSettings {
    static let defaultsKey = "language"

    @ObservationIgnored private let defaults: UserDefaults
    let folder: LanguageFolder
    /// A language the user may choose, named in itself
    struct Option: Identifiable, Equatable {
        let code: String
        let name: String
        var id: String { code }
    }

    /// The base language and the files, the base file not twice
    let languages: [Option]
    /// The code this launch speaks
    let current: String
    /// Its strings over the base ones, for Localization
    let catalog: [String: String]

    /// The language for the next launch; a saved one whose file is gone shows as the base it fell back to
    var chosen: String {
        didSet { defaults.set(chosen, forKey: Self.defaultsKey) }
    }

    /// Seeds and reads the folder and resolves the language and its catalog
    init(folder: LanguageFolder, defaults: UserDefaults = .standard) {
        self.folder = folder
        self.defaults = defaults
        folder.seed(from: .main)
        let files = folder.read()
        current = LanguageChoice.resolve(
            saved: defaults.string(forKey: Self.defaultsKey), available: Set(files.map(\.code)))
        chosen = current
        // The base language keeps its own name whatever the interface speaks
        languages =
            [Option(code: LanguageFolder.baseCode, name: TextKey.languageBaseName.baseText)]
            + files.filter { $0.code != LanguageFolder.baseCode }.map { Option(code: $0.code, name: $0.name) }
        catalog = LanguageChoice.catalog(files: files, code: current)
    }

    /// Shows the folder in the Finder, making it first when the user removed it
    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder.url)
    }

    /// Writes the base file for editing and shows it in the Finder
    func createBaseFile() throws {
        let file = try folder.writeBaseFile()
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
