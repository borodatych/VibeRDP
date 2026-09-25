import Carbon.HIToolbox
import Foundation
import Observation
import VibeRDPCore

/// A modifier key of the Mac that goes to Windows as a modifier of the user's choice, told apart by its side
/// Shift and Caps Lock are the same on both keyboards and go as they are
enum MacModifier: String, CaseIterable, Codable, CodingKeyRepresentable, Identifiable {
    case leftControl, rightControl, leftOption, rightOption, leftCommand, rightCommand

    init?(keyCode: UInt16) {
        guard let modifier = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = modifier
    }

    var id: Self { self }

    var keyCode: UInt16 {
        let code =
            switch self {
            case .leftControl: kVK_Control
            case .rightControl: kVK_RightControl
            case .leftOption: kVK_Option
            case .rightOption: kVK_RightOption
            case .leftCommand: kVK_Command
            case .rightCommand: kVK_RightCommand
            }
        return UInt16(code)
    }

    var isRight: Bool {
        [.rightControl, .rightOption, .rightCommand].contains(self)
    }
}

/// A modifier of the PC keyboard; a right Mac key becomes the right PC key, so the right Alt stays AltGr
enum WindowsModifier: String, CaseIterable, Codable, Identifiable {
    case control, alt, windows

    var id: Self { self }

    func scanCode(right: Bool) -> UInt16 {
        let extended = UInt16(VRC_KEY_EXTENDED)
        return switch self {
        case .control: right ? extended | 0x1D : 0x1D
        case .alt: right ? extended | 0x38 : 0x38
        case .windows: right ? extended | 0x5C : extended | 0x5B
        }
    }
}

/// How the Mac keyboard works on the remote desktop
struct KeyboardSettings: Codable, Equatable {
    var modifiers: [MacModifier: WindowsModifier]
    /// Combinations the Mac keeps while the desktop has the keyboard: they reach the menus of the app, not Windows
    var macShortcuts: [Shortcut]
    /// Kept on the Mac as well; nil leaves the menu item without a shortcut
    var disconnect: Shortcut?
    /// The keyboard has the extra key between the left Shift and Z
    var isoKeyboard: Bool

    /// ⌘C and the like work as the hand expects: the left ⌘ is Ctrl, and the right one is left for the Windows key
    static let macModifiers: [MacModifier: WindowsModifier] = [
        .leftControl: .control, .rightControl: .control, .leftOption: .alt, .rightOption: .alt,
        .leftCommand: .control, .rightCommand: .windows,
    ]

    /// Every key where a PC keyboard has it: ⌘ is the Windows key
    static let pcModifiers: [MacModifier: WindowsModifier] = [
        .leftControl: .control, .rightControl: .control, .leftOption: .alt, .rightOption: .alt,
        .leftCommand: .windows, .rightCommand: .windows,
    ]

    static let standard = KeyboardSettings(
        modifiers: macModifiers,
        macShortcuts: [
            shortcut(kVK_ANSI_Q, [.command]), shortcut(kVK_ANSI_H, [.command]),
            shortcut(kVK_ANSI_H, [.option, .command]), shortcut(kVK_ANSI_M, [.command]),
            shortcut(kVK_ANSI_Comma, [.command]), shortcut(kVK_ANSI_F, [.function]),
            shortcut(kVK_ANSI_F, [.control, .command]),
        ],
        disconnect: shortcut(kVK_ANSI_W, [.option, .command]),
        isoKeyboard: false)

    /// A key missing from stored settings keeps its place of the Mac preset, which names every key
    func target(of modifier: MacModifier) -> WindowsModifier {
        modifiers[modifier] ?? Self.macModifiers[modifier]!
    }

    func keepsOnMac(_ shortcut: Shortcut) -> Bool {
        shortcut == disconnect || macShortcuts.contains(shortcut)
    }

    /// A combination already on the list is not added twice
    mutating func keepOnMac(_ shortcut: Shortcut) {
        if !macShortcuts.contains(shortcut) {
            macShortcuts.append(shortcut)
        }
    }

    private static func shortcut(_ keyCode: Int, _ modifiers: Shortcut.Modifiers) -> Shortcut {
        Shortcut(keyCode: UInt16(keyCode), modifiers: modifiers)!
    }
}

/// Where a session reads its keyboard settings from, at every key, so a change applies at once
@MainActor
protocol KeyboardSettingsSource: AnyObject {
    var settings: KeyboardSettings { get }
}

/// The keyboard settings of the app, kept in its defaults
/// A change is announced for the menu to follow, and the settings view observes the store
@MainActor
@Observable
final class KeyboardSettingsStore: KeyboardSettingsSource {
    static let defaultsKey = "keyboard"
    static let didChange = Notification.Name("tech.vibebrains.viberdp.keyboardSettingsDidChange")

    @ObservationIgnored private let defaults: UserDefaults

    var settings: KeyboardSettings {
        didSet {
            guard settings != oldValue else { return }
            if let data = try? JSONEncoder().encode(settings) {
                defaults.set(data, forKey: Self.defaultsKey)
            }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// Stored settings that do not decode, written by another version for one, give way to the standard ones
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings =
            defaults.data(forKey: Self.defaultsKey).flatMap {
                try? JSONDecoder().decode(KeyboardSettings.self, from: $0)
            }
            ?? .standard
    }
}
