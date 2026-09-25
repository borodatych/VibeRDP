import Foundation

/// A saved connection: where to connect, as whom, and how the keyboard works there
/// The password is not here: the Keychain keeps it under the id of the profile
struct ConnectionProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    /// What the list shows; empty shows the address instead
    var name: String
    /// host, host:port or [IPv6]:port, as ServerAddress reads it
    var address: String
    /// DOMAIN\user or user@domain, as the engine splits it; empty asks for it when the server needs it
    var username: String
    /// A password the user enters goes to the Keychain once the server accepts it
    var remembersPassword: Bool
    var keyboard: ProfileKeyboard

    init(
        id: UUID = UUID(), name: String = "", address: String = "", username: String = "",
        remembersPassword: Bool = true, keyboard: ProfileKeyboard = .settings
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.username = username
        self.remembersPassword = remembersPassword
        self.keyboard = keyboard
    }

    /// The name, or the address for a profile without one
    var title: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? address.trimmingCharacters(in: .whitespacesAndNewlines) : name
    }
}

/// The modifier keys of one connection: as the app settings say, or a preset of its own
/// The combinations the Mac keeps and the ISO switch stay the app's: they belong to the Mac, not to the server
enum ProfileKeyboard: String, Codable, CaseIterable, Identifiable, Sendable {
    case settings, mac, pc

    var id: Self { self }

    /// The settings a session of this profile uses
    func applied(to settings: KeyboardSettings) -> KeyboardSettings {
        var applied = settings
        switch self {
        case .settings: break
        case .mac: applied.modifiers = KeyboardSettings.macModifiers
        case .pc: applied.modifiers = KeyboardSettings.pcModifiers
        }
        return applied
    }
}

/// The keyboard settings of one session: the app settings as they are now, with the preset of the profile
@MainActor
final class ProfileKeyboardSettings: KeyboardSettingsSource {
    private let store: KeyboardSettingsStore
    private let keyboard: ProfileKeyboard

    init(store: KeyboardSettingsStore, keyboard: ProfileKeyboard) {
        self.store = store
        self.keyboard = keyboard
    }

    var settings: KeyboardSettings {
        keyboard.applied(to: store.settings)
    }
}
