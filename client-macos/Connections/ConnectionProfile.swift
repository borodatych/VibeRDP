import Foundation
import VibeRDPCore

/// A saved connection: where to connect, as whom, through which gateway, how the keyboard works there,
/// and how large the desktop is
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
    var displayMode: ProfileDisplayMode
    /// The desktop of the fixed mode; the other modes keep it for when the mode comes back
    var fixedSize: DesktopSize
    /// On a Retina display the desktop takes its pixels, so the text is sharp; off, the display stretches it,
    /// with four times fewer pixels to send
    var sharpOnRetina: Bool
    /// Where the sound of the remote computer plays
    var audio: ProfileAudio
    /// A folder of the Mac Windows sees as a drive; empty shares none
    var sharedFolder: String
    /// Shown under Favourites in the sidebar
    var isFavorite: Bool
    /// When a session of the profile last got in, for sorting; nil before the first one
    var lastConnected: Date?

    init(
        id: UUID = UUID(), name: String = "", address: String = "", username: String = "",
        remembersPassword: Bool = true, keyboard: ProfileKeyboard = .settings, gatewayAddress: String = "",
        gatewayUsesServerCredentials: Bool = true, gatewayUsername: String = "", gatewayBypassLocal: Bool = false,
        displayMode: ProfileDisplayMode = .window, fixedSize: DesktopSize = .standard, sharpOnRetina: Bool = true,
        audio: ProfileAudio = .local, sharedFolder: String = "", isFavorite: Bool = false,
        lastConnected: Date? = nil
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
        self.displayMode = displayMode
        self.fixedSize = fixedSize
        self.sharpOnRetina = sharpOnRetina
        self.audio = audio
        self.sharedFolder = sharedFolder
        self.isFavorite = isFavorite
        self.lastConnected = lastConnected
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
        displayMode =
            try container.decodeIfPresent(ProfileDisplayMode.self, forKey: .displayMode) ?? defaults.displayMode
        fixedSize = try container.decodeIfPresent(DesktopSize.self, forKey: .fixedSize) ?? defaults.fixedSize
        sharpOnRetina = try container.decodeIfPresent(Bool.self, forKey: .sharpOnRetina) ?? defaults.sharpOnRetina
        audio = try container.decodeIfPresent(ProfileAudio.self, forKey: .audio) ?? defaults.audio
        sharedFolder = try container.decodeIfPresent(String.self, forKey: .sharedFolder) ?? defaults.sharedFolder
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? defaults.isFavorite
        lastConnected = try container.decodeIfPresent(Date.self, forKey: .lastConnected)
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

/// Where the sound of the remote computer plays, as Windows App offers it
enum ProfileAudio: String, Codable, CaseIterable, Identifiable, Sendable {
    /// On this Mac
    case local
    /// On the remote computer itself
    case remote
    /// Nowhere
    case off

    var id: Self { self }

    /// The mode of the core
    var mode: VRCAudioMode {
        switch self {
        case .local: .local
        case .remote: .remote
        case .off: .off
        }
    }
}

/// How large the remote desktop is, and how the session window shows it
enum ProfileDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The desktop follows the session window as it changes; the window opens as the last one was
    case window
    /// The window opens over all the free space of the screen, as a double click on its title makes it,
    /// and the desktop follows it after that
    case maximized
    /// The session opens in full screen; out of it, the desktop follows the window as in the window mode
    case fullScreen
    /// The desktop keeps its size, and the window scales it with bars at the sides
    case fixed

    var id: Self { self }
}

/// A desktop size in pixels of Windows
struct DesktopSize: Codable, Hashable, Sendable {
    var width: Int
    var height: Int

    /// The limits of the protocol for a monitor, on each side
    static let minimumSide = 200
    static let maximumSide = 8192
    /// The size a fixed desktop starts with
    static let standard = DesktopSize(width: 1920, height: 1080)
    /// The sizes the editor offers, the common ones of monitors and laptops
    static let presets = [
        DesktopSize(width: 1280, height: 720), DesktopSize(width: 1280, height: 800),
        DesktopSize(width: 1366, height: 768), DesktopSize(width: 1440, height: 900),
        DesktopSize(width: 1600, height: 900), DesktopSize(width: 1680, height: 1050),
        DesktopSize(width: 1920, height: 1080), DesktopSize(width: 1920, height: 1200),
        DesktopSize(width: 2560, height: 1440), DesktopSize(width: 2560, height: 1600),
        DesktopSize(width: 3840, height: 2160),
    ]

    /// Within the limits of the protocol, the width even: the server takes no other
    var clamped: DesktopSize {
        let width = min(max(width, Self.minimumSide), Self.maximumSide) & ~1
        let height = min(max(height, Self.minimumSide), Self.maximumSide)
        return DesktopSize(width: width, height: height)
    }

    var cgSize: CGSize {
        CGSize(width: width, height: height)
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
