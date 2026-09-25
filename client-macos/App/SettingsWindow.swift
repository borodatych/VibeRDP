import AppKit
import SwiftUI

/// The settings of the app in a window of their own, a tab for each part; the keyboard is the first
/// The window and its tabs are AppKit, as the rest of the app, and each tab is a SwiftUI view
@MainActor
final class SettingsWindowController: NSWindowController {
    init(keyboard: KeyboardSettingsStore, languages: LanguageSettings) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let keyboardTab = NSTabViewItem(
            viewController: NSHostingController(rootView: KeyboardSettingsView(store: keyboard)))
        keyboardTab.label = Localization.text(.settingsKeyboardTab)
        keyboardTab.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        tabs.addTabViewItem(keyboardTab)
        let languageTab = NSTabViewItem(
            viewController: NSHostingController(rootView: LanguageSettingsView(settings: languages)))
        languageTab.label = Localization.text(.settingsLanguageTab)
        languageTab.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        tabs.addTabViewItem(languageTab)

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = Localization.text(.settingsTitle)
        window.isReleasedWhenClosed = false
        // The tab controller keeps the size the window was made with, not the one its tab asks for
        window.setContentSize(KeyboardSettingsView.size)
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the window is built in code")
    }
}

/// The keyboard tab: what each Mac modifier is on Windows, the combinations the Mac keeps, and Disconnect
/// Every change goes to the store at once, as macOS settings do, without an Apply button
struct KeyboardSettingsView: View {
    /// A grouped form scrolls and has no height of its own, so the tab gets one, as panes of System Settings do
    static let size = CGSize(width: 480, height: 640)
    static let listHeight: CGFloat = 132

    @Bindable var store: KeyboardSettingsStore
    @State private var selection: Set<Shortcut> = []

    var body: some View {
        Form {
            Section(Localization.text(.settingsKeyboardModifiers)) {
                ForEach(MacModifier.allCases) { modifier in
                    Picker(Localization.text(Self.title(of: modifier)), selection: target(of: modifier)) {
                        ForEach(WindowsModifier.allCases) { target in
                            Text(Localization.text(Self.title(of: target))).tag(target)
                        }
                    }
                }
                HStack {
                    Button(Localization.text(.settingsKeyboardPresetMac)) {
                        store.settings.modifiers = KeyboardSettings.macModifiers
                    }
                    Button(Localization.text(.settingsKeyboardPresetPC)) {
                        store.settings.modifiers = KeyboardSettings.pcModifiers
                    }
                }
                Toggle(isOn: $store.settings.isoKeyboard) {
                    Text(Localization.text(.settingsKeyboardIso))
                    Text(Localization.text(.settingsKeyboardIsoHint))
                }
            }

            Section {
                List(store.settings.macShortcuts, id: \.self, selection: $selection) { shortcut in
                    Text(shortcut.displayName)
                }
                .frame(height: Self.listHeight)
                HStack {
                    ShortcutRecorder(placeholder: Localization.text(.settingsKeyboardAdd), shortcut: nil) { shortcut in
                        if let shortcut {
                            store.settings.keepOnMac(shortcut)
                        }
                    }
                    Button(Localization.text(.settingsKeyboardRemove)) {
                        store.settings.macShortcuts.removeAll { selection.contains($0) }
                        selection = []
                    }
                    .disabled(selection.isEmpty)
                }
            } header: {
                Text(Localization.text(.settingsKeyboardMacShortcuts))
            } footer: {
                Text(Localization.text(.settingsKeyboardMacShortcutsHint))
            }

            Section {
                LabeledContent(Localization.text(.settingsKeyboardDisconnect)) {
                    ShortcutRecorder(placeholder: Localization.text(.shortcutNone), shortcut: store.settings.disconnect)
                    {
                        store.settings.disconnect = $0
                    }
                }
            } footer: {
                Text(Localization.text(.shortcutHint))
            }

            Button(Localization.text(.settingsKeyboardReset)) {
                store.settings = .standard
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// The popup of a modifier shows what the settings give it, the Mac preset for a key they do not name
    private func target(of modifier: MacModifier) -> Binding<WindowsModifier> {
        Binding(
            get: { store.settings.target(of: modifier) },
            set: { store.settings.modifiers[modifier] = $0 })
    }

    static func title(of modifier: MacModifier) -> TextKey {
        switch modifier {
        case .leftControl: .settingsKeyboardLeftControl
        case .rightControl: .settingsKeyboardRightControl
        case .leftOption: .settingsKeyboardLeftOption
        case .rightOption: .settingsKeyboardRightOption
        case .leftCommand: .settingsKeyboardLeftCommand
        case .rightCommand: .settingsKeyboardRightCommand
        }
    }

    static func title(of target: WindowsModifier) -> TextKey {
        switch target {
        case .control: .settingsKeyboardControl
        case .alt: .settingsKeyboardAlt
        case .windows: .settingsKeyboardWindows
        }
    }
}

/// The language tab: the languages of the folder, the choice for the next launch, and the folder itself
struct LanguageSettingsView: View {
    @Bindable var settings: LanguageSettings
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                Picker(Localization.text(.settingsLanguageLabel), selection: $settings.chosen) {
                    ForEach(settings.languages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
            } footer: {
                Text(Localization.text(.settingsLanguageRestart))
            }
            Section {
                HStack {
                    Button(Localization.text(.settingsLanguageOpenFolder)) {
                        settings.revealFolder()
                    }
                    Button(Localization.text(.settingsLanguageCreateBase)) {
                        do {
                            try settings.createBaseFile()
                            failure = nil
                        } catch {
                            failure = Localization.text(
                                .settingsLanguageCreateBaseFailed, ["reason": error.localizedDescription])
                        }
                    }
                }
                if let failure {
                    Text(failure)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text(Localization.text(.settingsLanguageFolderHint, ["folder": settings.folder.url.path]))
            }
        }
        .formStyle(.grouped)
        .frame(width: KeyboardSettingsView.size.width, height: KeyboardSettingsView.size.height)
    }
}

/// The AppKit recorder in a SwiftUI form: SwiftUI has no way to take ⌘Q before the menus do
struct ShortcutRecorder: NSViewRepresentable {
    let placeholder: String
    let shortcut: Shortcut?
    let onRecord: (Shortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutField {
        ShortcutField()
    }

    func updateNSView(_ field: ShortcutField, context: Context) {
        field.placeholder = placeholder
        field.shortcut = shortcut
        field.onRecord = onRecord
    }
}
