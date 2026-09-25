import Foundation

/// A saved connection: where to connect, as whom, through which gateway, and how the keyboard works there
/// The passwords are not here: the Keychain keeps them under the id of the profile
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
    /// RD Gateway in front of the computer, as the address; empty connects directly
    var gatewayAddress: String
    /// The gateway takes the name and password of the computer, as most corporate gateways do
    var gatewayUsesServerCredentials: Bool
    /// The gateway's own user name, when it does not take those of the computer
    var gatewayUsername: String
    /// Addresses of the local network skip the gateway
    var gatewayBypassLocal: Bool

    init(
        id: UUID = UUID(), name: String = "", address: String = "", username: String = "",
        remembersPassword: Bool = true, keyboard: ProfileKeyboard = .settings, gatewayAddress: String = "",
        gatewayUsesServerCredentials: Bool = true, gatewayUsername: String = "", gatewayBypassLocal: Bool = false
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.username = username
        self.remembersPassword = remembersPassword
        self.keyboard = keyboard
        self.gatewayAddress = gatewayAddress
        self.gatewayUsesServerCredentials = gatewayUsesServerCredentials
        self.gatewayUsername = gatewayUsername
        self.gatewayBypassLocal = gatewayBypassLocal
    }

    /// A setting missing from stored data, as in profiles saved before it existed, takes its default
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ConnectionProfile(id: try container.decode(UUID.self, forKey: .id))
        id = defaults.id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? defaults.address
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? defaults.username
        remembersPassword =
            try container.decodeIfPresent(Bool.self, forKey: .remembersPassword) ?? defaults.remembersPassword
        keyboard = try container.decodeIfPresent(ProfileKeyboard.self, forKey: .keyboard) ?? defaults.keyboard
        gatewayAddress = try container.decodeIfPresent(String.self, forKey: .gatewayAddress) ?? defaults.gatewayAddress
        gatewayUsesServerCredentials =
            try container.decodeIfPresent(Bool.self, forKey: .gatewayUsesServerCredentials)
            ?? defaults.gatewayUsesServerCredentials
        gatewayUsername =
            try container.decodeIfPresent(String.self, forKey: .gatewayUsername) ?? defaults.gatewayUsername
        gatewayBypassLocal =
            try container.decodeIfPresent(Bool.self, forKey: .gatewayBypassLocal) ?? defaults.gatewayBypassLocal
    }

    /// The name, or the address for a profile without one
    var title: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? address.trimmingCharacters(in: .whitespacesAndNewlines) : name
    }

    /// The gateway to go through: nil for a direct connection
    var gateway: ServerAddress? {
        ServerAddress(gatewayAddress)
    }

    /// The gateway field is empty or readable: an unreadable one must not quietly connect directly
    var hasValidGateway: Bool {
        gatewayAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || gateway != nil
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
