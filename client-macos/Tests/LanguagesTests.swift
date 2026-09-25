import XCTest

@testable import VibeRDP

/// The folder of languages, the choice of a language and the catalog it gives
@MainActor
final class LanguagesTests: XCTestCase {
    private var folder: LanguageFolder!
    private var suiteName = ""

    override func setUp() async throws {
        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        folder = LanguageFolder(url: url)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder.url)
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    /// The app lays out English and the sample, keeps a file the user changed and brings back one the user deleted
    func testSeedKeepsChangesAndRestoresDeletions() throws {
        folder.seed(from: .main)
        let english = folder.url.appendingPathComponent("en.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: english.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("example.jsonc").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("ru.json").path))

        try Data(#"{"$name": "Mine", "menu.file": "Files"}"#.utf8).write(to: english)
        folder.seed(from: .main)
        XCTAssertEqual(folder.read().first { $0.code == "en" }?.strings, ["menu.file": "Files"])

        try FileManager.default.removeItem(at: english)
        folder.seed(from: .main)
        XCTAssertEqual(folder.read().first { $0.code == "en" }?.name, "English")
    }

    /// Only .json files count; a broken one is left out, values that are no strings too, and $ keys are no strings
    func testReadTakesWhatReads() throws {
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data(#"{"$name": "Deutsch", "menu.file": "Ablage", "count": 3}"#.utf8)
            .write(to: folder.url.appendingPathComponent("de.json"))
        try Data(#"{"menu.file": "#.utf8).write(to: folder.url.appendingPathComponent("broken.json"))
        try Data(#"{"menu.file": "x"}"#.utf8).write(to: folder.url.appendingPathComponent("notes.txt"))
        try Data(#"{"menu.file": "Plik"}"#.utf8).write(to: folder.url.appendingPathComponent("pl.json"))

        let languages = folder.read()
        XCTAssertEqual(languages.map(\.code), ["de", "pl"])
        XCTAssertEqual(languages[0].name, "Deutsch")
        XCTAssertEqual(languages[0].strings, ["menu.file": "Ablage"])
        XCTAssertEqual(languages[1].name, "pl", "without $name the code names the language")
    }

    /// The file for editing holds every base string and its name; an existing one keeps the user's corrections
    func testBaseFileForEditing() throws {
        let file = try folder.writeBaseFile()
        let base = try XCTUnwrap(LanguageFolder.language(at: file))
        XCTAssertEqual(base.code, "ru")
        XCTAssertEqual(base.name, TextKey.languageBaseName.baseText)
        XCTAssertEqual(base.strings.count, TextKey.allCases.count)
        XCTAssertEqual(base.strings[TextKey.menuFile.rawValue], TextKey.menuFile.baseText)

        try Data(#"{"menu.file": "Файлы"}"#.utf8).write(to: file)
        XCTAssertEqual(try folder.writeBaseFile(), file)
        XCTAssertEqual(LanguageFolder.language(at: file)?.strings, ["menu.file": "Файлы"])
    }

    /// The saved choice while its file is there, else Russian: the language of the system plays no part
    func testChoiceFallsBackToRussian() {
        let available: Set = ["en", "de"]
        XCTAssertEqual(LanguageChoice.resolve(saved: "de", available: available), "de")
        XCTAssertEqual(LanguageChoice.resolve(saved: "elvish", available: available), "ru")
        XCTAssertEqual(LanguageChoice.resolve(saved: nil, available: available), "ru")
        XCTAssertEqual(LanguageChoice.resolve(saved: "ru", available: []), "ru")
    }

    /// A language over the corrected base: its own strings win, the corrections fill what it leaves out
    func testCatalogLayers() {
        let base = LanguageFile(code: "ru", name: "Русский", strings: ["menu.file": "Файлы", "menu.window": "Окна"])
        let german = LanguageFile(code: "de", name: "Deutsch", strings: ["menu.file": "Ablage"])
        XCTAssertEqual(
            LanguageChoice.catalog(files: [base, german], code: "de"), ["menu.file": "Ablage", "menu.window": "Окна"])
        XCTAssertEqual(LanguageChoice.catalog(files: [base, german], code: "ru"), base.strings)
        XCTAssertEqual(LanguageChoice.catalog(files: [german], code: "ru"), [:])
        XCTAssertEqual(LanguageChoice.catalog(files: [german], code: "de"), german.strings)
    }

    /// The settings read the folder once: the list, the language of this launch and the choice for the next one
    func testSettingsListAndRememberTheChoice() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let fresh = LanguageSettings(folder: folder, defaults: defaults)
        XCTAssertEqual(fresh.current, "ru")
        XCTAssertEqual(fresh.chosen, "ru")
        XCTAssertEqual(fresh.catalog, [:])

        defaults.set("en", forKey: LanguageSettings.defaultsKey)
        let settings = LanguageSettings(folder: folder, defaults: defaults)
        XCTAssertEqual(settings.current, "en")
        XCTAssertEqual(settings.languages.map(\.code), ["ru", "en"])
        XCTAssertEqual(settings.catalog[TextKey.menuFile.rawValue], "File")

        // A language whose file is gone falls back to Russian and shows so in the choice
        defaults.set("elvish", forKey: LanguageSettings.defaultsKey)
        XCTAssertEqual(LanguageSettings(folder: folder, defaults: defaults).chosen, "ru")

        settings.chosen = "ru"
        XCTAssertEqual(defaults.string(forKey: LanguageSettings.defaultsKey), "ru")
    }

    /// The bundle carries the seeded languages and the English strings macOS shows before the app runs
    func testBundleCarriesLanguagesAndInfoPlistStrings() {
        XCTAssertNotNil(Bundle.main.url(forResource: "en.json", withExtension: nil, subdirectory: "lang"))
        XCTAssertNotNil(Bundle.main.url(forResource: "example.jsonc", withExtension: nil, subdirectory: "lang"))
        XCTAssertNotNil(
            Bundle.main.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: "en"))
    }
}
