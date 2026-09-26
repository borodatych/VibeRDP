import AppKit
import Carbon.HIToolbox
import VibeRDPCore
import XCTest

@testable import VibeRDP

private let extended = UInt16(VRC_KEY_EXTENDED)

/// The place of a Mac key on the PC keyboard
final class KeyCodeMapTests: XCTestCase {
    func testLettersDigitsAndControlKeys() {
        XCTAssertEqual(scanCode(kVK_ANSI_A), 0x1E)
        XCTAssertEqual(scanCode(kVK_ANSI_Z), 0x2C)
        XCTAssertEqual(scanCode(kVK_ANSI_1), 0x02)
        XCTAssertEqual(scanCode(kVK_ANSI_0), 0x0B)
        XCTAssertEqual(scanCode(kVK_Return), 0x1C)
        XCTAssertEqual(scanCode(kVK_Delete), 0x0E)
        XCTAssertEqual(scanCode(kVK_Escape), 0x01)
        XCTAssertEqual(scanCode(kVK_Shift), 0x2A)
        XCTAssertEqual(scanCode(kVK_RightShift), 0x36)
        XCTAssertEqual(scanCode(kVK_CapsLock), 0x3A)
    }

    /// The keys a real PC keyboard prefixes with E0 carry the extended bit
    func testExtendedKeys() {
        XCTAssertEqual(scanCode(kVK_LeftArrow), extended | 0x4B)
        XCTAssertEqual(scanCode(kVK_ForwardDelete), extended | 0x53)
        XCTAssertEqual(scanCode(kVK_ANSI_KeypadEnter), extended | 0x1C)
        XCTAssertEqual(scanCode(kVK_ANSI_KeypadDivide), extended | 0x35)
        XCTAssertEqual(scanCode(kVK_Help), extended | 0x52)
        XCTAssertEqual(scanCode(kVK_F13), extended | 0x37)
        XCTAssertEqual(scanCode(kVK_F15), UInt16(VRC_KEY_PAUSE))
    }

    /// fn and the modifiers the settings choose for have no fixed place here
    func testKeysWithoutAFixedPlace() {
        XCTAssertNil(scanCode(kVK_Function))
        XCTAssertNil(scanCode(kVK_Command))
        XCTAssertNil(scanCode(kVK_RightOption))
        XCTAssertNil(scanCode(kVK_Control))
    }

    /// On ISO keyboards macOS gives the key left of 1 and the one beside the left Shift each other's codes
    func testIsoKeyboardSwapsTheTwoKeys() {
        XCTAssertEqual(scanCode(kVK_ANSI_Grave), 0x29)
        XCTAssertEqual(scanCode(kVK_ISO_Section), 0x56)
        XCTAssertEqual(scanCode(kVK_ANSI_Grave, iso: true), 0x56)
        XCTAssertEqual(scanCode(kVK_ISO_Section, iso: true), 0x29)
    }

    /// Every scan code is one the core accepts: at most 0x7F, with no other bit than the extended one
    func testEveryScanCodeIsValid() {
        for keyCode in UInt16(0)...0x7F {
            for iso in [false, true] {
                guard let code = KeyCodeMap.scanCode(of: keyCode, iso: iso) else { continue }
                XCTAssertTrue(code & 0xFF != 0 && code & 0xFF <= 0x7F, "key code \(keyCode)")
                XCTAssertEqual(code & ~(extended | 0xFF), 0, "key code \(keyCode)")
            }
        }
    }

    private func scanCode(_ keyCode: Int, iso: Bool = false) -> UInt16? {
        KeyCodeMap.scanCode(of: UInt16(keyCode), iso: iso)
    }
}

/// Shortcuts, the settings and their store
@MainActor
final class KeyboardSettingsTests: XCTestCase {
    private var suiteName = ""

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    /// A shortcut needs ⌃, ⌥, ⌘ or fn, and a key it can name
    func testShortcutNeedsAModifierAndANamedKey() {
        XCTAssertNil(Shortcut(keyCode: UInt16(kVK_ANSI_W), modifiers: []))
        XCTAssertNil(Shortcut(keyCode: UInt16(kVK_ANSI_W), modifiers: [.shift]))
        XCTAssertNil(Shortcut(keyCode: UInt16(kVK_Function), modifiers: [.command]))
        XCTAssertNotNil(Shortcut(keyCode: UInt16(kVK_ANSI_W), modifiers: [.shift, .command]))
        XCTAssertNotNil(Shortcut(keyCode: UInt16(kVK_ANSI_F), modifiers: [.function]))
    }

    /// macOS flags the arrows and the function keys with fn itself: such a flag is not part of the shortcut
    func testImpliedFunctionFlagIsDropped() {
        let arrow = Shortcut(keyCode: UInt16(kVK_LeftArrow), modifiers: [.command, .function])
        XCTAssertEqual(arrow?.modifiers, [.command])
        XCTAssertNil(Shortcut(keyCode: UInt16(kVK_F5), modifiers: [.function]))
    }

    func testDisplayNameAndMenuEquivalent() throws {
        let disconnect = try XCTUnwrap(KeyboardSettings.standard.disconnect)
        XCTAssertEqual(disconnect.displayName, "⌥⌘W")
        XCTAssertEqual(disconnect.menuKeyEquivalent.key, "w")
        XCTAssertEqual(disconnect.menuKeyEquivalent.mask, [.option, .command])
        let full = try XCTUnwrap(Shortcut(keyCode: UInt16(kVK_ANSI_F), modifiers: [.control, .command, .function]))
        XCTAssertEqual(full.displayName, "fn ⌃⌘F")
        let arrow = try XCTUnwrap(Shortcut(keyCode: UInt16(kVK_UpArrow), modifiers: [.shift, .option]))
        XCTAssertEqual(arrow.displayName, "⌥⇧↑")
        XCTAssertEqual(arrow.menuKeyEquivalent.key, String(Character(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)))
    }

    /// The Mac preset: ⌘C is Ctrl+C, the right ⌘ is the Windows key; the PC preset: ⌘ is the Windows key
    func testPresetsNameEveryModifier() {
        for modifier in MacModifier.allCases {
            XCTAssertNotNil(KeyboardSettings.macModifiers[modifier], "\(modifier)")
            XCTAssertNotNil(KeyboardSettings.pcModifiers[modifier], "\(modifier)")
        }
        XCTAssertEqual(KeyboardSettings.macModifiers[.leftCommand], .control)
        XCTAssertEqual(KeyboardSettings.macModifiers[.rightCommand], .windows)
        XCTAssertEqual(KeyboardSettings.pcModifiers[.leftCommand], .windows)
        XCTAssertEqual(KeyboardSettings.standard.modifiers, KeyboardSettings.macModifiers)
    }

    /// The Mac keeps its menus: quit, hide, minimize, settings, full screen and Disconnect; ⌘W goes to Windows
    func testStandardShortcutsKeptOnMac() throws {
        let settings = KeyboardSettings.standard
        let kept: [(Int, Shortcut.Modifiers)] = [
            (kVK_ANSI_Q, [.command]), (kVK_ANSI_H, [.command]), (kVK_ANSI_H, [.option, .command]),
            (kVK_ANSI_M, [.command]), (kVK_ANSI_Comma, [.command]), (kVK_ANSI_F, [.function]),
            (kVK_ANSI_F, [.control, .command]), (kVK_ANSI_W, [.option, .command]),
        ]
        for (key, modifiers) in kept {
            let shortcut = try XCTUnwrap(Shortcut(keyCode: UInt16(key), modifiers: modifiers))
            XCTAssertTrue(settings.keepsOnMac(shortcut), shortcut.displayName)
        }
        let close = try XCTUnwrap(Shortcut(keyCode: UInt16(kVK_ANSI_W), modifiers: [.command]))
        XCTAssertFalse(settings.keepsOnMac(close))
    }

    /// A combination goes on the list of the Mac once
    func testKeepOnMacAddsOnce() throws {
        let cycle = try XCTUnwrap(Shortcut(keyCode: UInt16(kVK_ANSI_Grave), modifiers: [.command]))
        var settings = KeyboardSettings.standard
        settings.keepOnMac(cycle)
        settings.keepOnMac(cycle)
        XCTAssertEqual(settings.macShortcuts.filter { $0 == cycle }.count, 1)
        XCTAssertEqual(settings.macShortcuts.count, KeyboardSettings.standard.macShortcuts.count + 1)
        XCTAssertTrue(settings.keepsOnMac(cycle))
    }

    func testStoreKeepsSettingsAndAnnouncesChanges() throws {
        let defaults = try makeDefaults()
        let store = KeyboardSettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings, .standard)

        let announced = expectation(forNotification: KeyboardSettingsStore.didChange, object: store)
        var changed = store.settings
        changed.modifiers = KeyboardSettings.pcModifiers
        changed.isoKeyboard = true
        changed.disconnect = nil
        store.settings = changed
        wait(for: [announced], timeout: 1)

        XCTAssertEqual(KeyboardSettingsStore(defaults: defaults).settings, changed)
    }

    /// Settings that do not decode give way to the standard ones; a modifier missing from them keeps the Mac preset
    func testUnreadableOrPartialSettings() throws {
        let defaults = try makeDefaults()
        defaults.set(Data("not json".utf8), forKey: KeyboardSettingsStore.defaultsKey)
        XCTAssertEqual(KeyboardSettingsStore(defaults: defaults).settings, .standard)

        var partial = KeyboardSettings.standard
        partial.modifiers = [.leftCommand: .alt]
        XCTAssertEqual(partial.target(of: .leftCommand), .alt)
        XCTAssertEqual(partial.target(of: .rightCommand), .windows)
    }

    private func makeDefaults() throws -> UserDefaults {
        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }
}

/// Mac keys turned into PC keys, and the combinations the Mac keeps
final class KeyboardTranslatorTests: XCTestCase {
    private var translator = KeyboardTranslator()
    private var settings = KeyboardSettings.standard

    /// ⌘C with the Mac preset: the left ⌘ goes as the left Ctrl, then C, then both released
    func testCommandCopyIsControlC() {
        XCTAssertEqual(modifier(kVK_Command, down: true), [send(0x1D, true)])
        XCTAssertEqual(down(kVK_ANSI_C, [.command]), [send(0x2E, true)])
        XCTAssertEqual(up(kVK_ANSI_C), [send(0x2E, false)])
        XCTAssertEqual(modifier(kVK_Command, down: false), [send(0x1D, false)])
    }

    /// The right key of a pair stays right: the right ⌥ is AltGr, the right ⌃ the right Ctrl
    func testSidesOfModifiers() {
        XCTAssertEqual(modifier(kVK_RightCommand, down: true), [send(extended | 0x5C, true)])
        XCTAssertEqual(modifier(kVK_RightOption, down: true), [send(extended | 0x38, true)])
        XCTAssertEqual(modifier(kVK_RightControl, down: true), [send(extended | 0x1D, true)])
        XCTAssertEqual(modifier(kVK_Option, down: true), [send(0x38, true)])
        XCTAssertEqual(modifier(kVK_Control, down: true), [send(0x1D, true)])
        XCTAssertEqual(modifier(kVK_RightShift, down: true), [send(0x36, true)])
    }

    func testPcPresetMakesCommandTheWindowsKey() {
        settings.modifiers = KeyboardSettings.pcModifiers
        XCTAssertEqual(modifier(kVK_Command, down: true), [send(extended | 0x5B, true)])
        XCTAssertEqual(modifier(kVK_RightCommand, down: false), [send(extended | 0x5C, false)])
    }

    /// A kept combination goes to the Mac with its repeats and its release, even with ⌘ already let go
    func testKeptCombinationStaysWholeOnTheMac() {
        XCTAssertEqual(down(kVK_ANSI_Q, [.command]), [.passToMac])
        XCTAssertEqual(down(kVK_ANSI_Q, [.command], repeating: true), [.passToMac])
        XCTAssertEqual(modifier(kVK_Command, down: false), [send(0x1D, false)])
        XCTAssertEqual(up(kVK_ANSI_Q), [.passToMac])
        XCTAssertEqual(down(kVK_ANSI_Q, []), [send(0x10, true)])
    }

    func testDisconnectShortcutIsKept() {
        XCTAssertEqual(down(kVK_ANSI_W, [.option, .command]), [.passToMac])
        XCTAssertEqual(down(kVK_ANSI_E, [.command]), [send(0x12, true)])
    }

    /// Every change of Caps Lock is one press of the key on Windows
    func testCapsLockTogglesOnEveryChange() {
        let toggle: [KeyboardTranslator.Action] = [send(0x3A, true), send(0x3A, false)]
        XCTAssertEqual(modifier(kVK_CapsLock, down: true), toggle)
        XCTAssertEqual(modifier(kVK_CapsLock, down: false), toggle)
    }

    func testRepeatsAndKeysWithoutAPlace() {
        XCTAssertEqual(down(kVK_ANSI_A, [], repeating: true), [.send(key: 0x1E, pressed: true, repeat: true)])
        XCTAssertEqual(modifier(kVK_Function, down: true), [])
        XCTAssertEqual(down(kVK_JIS_Eisu, []), [])
    }

    func testIsoSettingSwapsKeys() {
        settings.isoKeyboard = true
        XCTAssertEqual(down(kVK_ISO_Section, []), [send(0x29, true)])
    }

    /// After a reset a release of a key the Mac kept belongs to nothing, and goes to Windows as a plain release
    func testResetForgetsKeptKeys() {
        XCTAssertEqual(down(kVK_ANSI_M, [.command]), [.passToMac])
        translator.reset()
        XCTAssertEqual(up(kVK_ANSI_M), [send(0x32, false)])
    }

    private func send(_ key: UInt16, _ pressed: Bool) -> KeyboardTranslator.Action {
        .send(key: key, pressed: pressed, repeat: false)
    }

    private func down(_ keyCode: Int, _ modifiers: Shortcut.Modifiers, repeating: Bool = false)
        -> [KeyboardTranslator.Action]
    {
        translator.translate(
            .down(keyCode: UInt16(keyCode), modifiers: modifiers, isRepeat: repeating), settings: settings)
    }

    private func up(_ keyCode: Int) -> [KeyboardTranslator.Action] {
        translator.translate(.up(keyCode: UInt16(keyCode)), settings: settings)
    }

    private func modifier(_ keyCode: Int, down: Bool) -> [KeyboardTranslator.Action] {
        translator.translate(.modifier(keyCode: UInt16(keyCode), down: down), settings: settings)
    }
}

/// The settings window: a SwiftUI tab over the store
@MainActor
final class KeyboardSettingsViewTests: XCTestCase {
    private var suiteName = ""

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    /// The window holds the keyboard tab at its size
    func testSettingsWindowShowsTheKeyboardTab() throws {
        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        let store = KeyboardSettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let folder = LanguageFolder(
            url: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true))
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let languages = LanguageSettings(folder: folder, defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let diagnostics = DiagnosticsSettings(
            folder: folder.url.appending(path: "logs"), defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            openLog: { _ in false })
        let session = SessionSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let controller = SettingsWindowController(
            keyboard: store, languages: languages, diagnostics: diagnostics, session: session)
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.title, Localization.text(.settingsTitle))
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        XCTAssertEqual(
            tabs.tabViewItems.map(\.label),
            [
                Localization.text(.settingsKeyboardTab), Localization.text(.settingsSessionTab),
                Localization.text(.settingsLanguageTab), Localization.text(.settingsDiagnosticsTab),
            ])

        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.frame.size.width, KeyboardSettingsView.size.width, accuracy: 1)
        XCTAssertEqual(content.frame.size.height, KeyboardSettingsView.size.height, accuracy: 1)
        window.close()
    }
}

/// The recorder takes the next combination, even one the menus would act on
@MainActor
final class ShortcutFieldTests: XCTestCase {
    private var field: ShortcutField!
    private var recorded: [Shortcut?] = []

    override func setUp() async throws {
        field = ShortcutField()
        recorded = []
        field.onRecord = { [weak self] in self?.recorded.append($0) }
    }

    func testRecordsACombination() {
        field.performClick(nil)
        XCTAssertTrue(field.isRecording)
        XCTAssertEqual(field.title, Localization.text(.shortcutRecording))
        // A modifier change and a key without ⌃, ⌥, ⌘ or fn are swallowed while the recording goes on
        XCTAssertTrue(field.takesKey(key(.flagsChanged, kVK_Command, [.command])))
        XCTAssertTrue(field.takesKey(key(.keyDown, kVK_ANSI_Q, [.shift])))
        XCTAssertTrue(field.isRecording)

        XCTAssertTrue(field.takesKey(key(.keyDown, kVK_ANSI_Q, [.command])))
        XCTAssertFalse(field.isRecording)
        XCTAssertEqual(recorded, [Shortcut(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command])])
        XCTAssertFalse(field.takesKey(key(.keyDown, kVK_ANSI_A, [.command])))
    }

    func testEscapeCancelsAndDeleteClears() {
        field.performClick(nil)
        XCTAssertTrue(field.takesKey(key(.keyDown, kVK_Escape, [])))
        XCTAssertFalse(field.isRecording)
        XCTAssertEqual(recorded, [])

        field.performClick(nil)
        XCTAssertTrue(field.takesKey(key(.keyDown, kVK_Delete, [])))
        XCTAssertEqual(recorded, [nil])
    }

    private func key(_ type: NSEvent.EventType, _ keyCode: Int, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(keyCode))!
    }
}
