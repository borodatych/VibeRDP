import AppKit
import Carbon.HIToolbox

/// A key combination of the Mac by the place of its key, so it holds whatever the input source
struct Shortcut: Codable, Hashable {
    struct Modifiers: OptionSet, Codable, Hashable {
        let rawValue: UInt8

        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
        /// fn, the globe key
        static let function = Modifiers(rawValue: 1 << 4)

        /// Without one of these a shortcut would take an ordinary key or a capital letter away from Windows
        static let required: Modifiers = [.control, .option, .command, .function]
    }

    let keyCode: UInt16
    let modifiers: Modifiers

    /// Nil for a key without a name here or a combination without ⌃, ⌥, ⌘ or fn
    /// macOS flags the function keys, the arrows and the navigation keys with fn by themselves, so fn is dropped there
    init?(keyCode: UInt16, modifiers: Modifiers) {
        guard let name = Self.names[keyCode] else { return nil }
        let own = name.impliesFunction ? modifiers.subtracting(.function) : modifiers
        guard !own.isDisjoint(with: Self.Modifiers.required) else { return nil }
        self.keyCode = keyCode
        self.modifiers = own
    }

    /// As menus show it: ⌃⌥⇧⌘ in this order, then the key
    var displayName: String {
        let symbols: [(Modifiers, String)] = [
            (.function, "fn "), (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
        ]
        let prefix = symbols.filter { modifiers.contains($0.0) }.map(\.1).joined()
        return prefix + (Self.names[keyCode]?.label ?? "")
    }

    /// The key equivalent and mask of a menu item that shows this shortcut
    var menuKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags) {
        (Self.names[keyCode]?.equivalent ?? "", modifiers.flags)
    }

    private struct Name {
        let label: String
        /// What NSMenuItem takes as its key equivalent
        let equivalent: String
        var impliesFunction = false
    }

    private static func functionKey(_ code: Int) -> String {
        String(Character(UnicodeScalar(UInt16(code))!))
    }

    private static let names: [UInt16: Name] = {
        var names: [Int: Name] = [:]
        let characters: [(Int, String)] = [
            (kVK_ANSI_A, "a"), (kVK_ANSI_B, "b"), (kVK_ANSI_C, "c"), (kVK_ANSI_D, "d"), (kVK_ANSI_E, "e"),
            (kVK_ANSI_F, "f"), (kVK_ANSI_G, "g"), (kVK_ANSI_H, "h"), (kVK_ANSI_I, "i"), (kVK_ANSI_J, "j"),
            (kVK_ANSI_K, "k"), (kVK_ANSI_L, "l"), (kVK_ANSI_M, "m"), (kVK_ANSI_N, "n"), (kVK_ANSI_O, "o"),
            (kVK_ANSI_P, "p"), (kVK_ANSI_Q, "q"), (kVK_ANSI_R, "r"), (kVK_ANSI_S, "s"), (kVK_ANSI_T, "t"),
            (kVK_ANSI_U, "u"), (kVK_ANSI_V, "v"), (kVK_ANSI_W, "w"), (kVK_ANSI_X, "x"), (kVK_ANSI_Y, "y"),
            (kVK_ANSI_Z, "z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
            (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]"),
            (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."),
            (kVK_ANSI_Slash, "/"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Grave, "`"), (kVK_ISO_Section, "§"),
        ]
        for (code, character) in characters {
            names[code] = Name(label: character.uppercased(), equivalent: character)
        }
        names[kVK_Return] = Name(label: "↩", equivalent: "\r")
        names[kVK_Tab] = Name(label: "⇥", equivalent: "\t")
        names[kVK_Space] = Name(label: "␣", equivalent: " ")
        names[kVK_Delete] = Name(label: "⌫", equivalent: "\u{8}")
        names[kVK_Escape] = Name(label: "⎋", equivalent: "\u{1B}")

        let navigation: [(Int, String, Int)] = [
            (kVK_LeftArrow, "←", NSLeftArrowFunctionKey), (kVK_RightArrow, "→", NSRightArrowFunctionKey),
            (kVK_UpArrow, "↑", NSUpArrowFunctionKey), (kVK_DownArrow, "↓", NSDownArrowFunctionKey),
            (kVK_Home, "↖", NSHomeFunctionKey), (kVK_End, "↘", NSEndFunctionKey),
            (kVK_PageUp, "⇞", NSPageUpFunctionKey), (kVK_PageDown, "⇟", NSPageDownFunctionKey),
            (kVK_ForwardDelete, "⌦", NSDeleteFunctionKey),
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        let numbered = functionKeys.enumerated().map { ($0.element, "F\($0.offset + 1)", NSF1FunctionKey + $0.offset) }
        for (code, label, key) in navigation + numbered {
            names[code] = Name(label: label, equivalent: functionKey(key), impliesFunction: true)
        }
        return Dictionary(uniqueKeysWithValues: names.map { (UInt16($0.key), $0.value) })
    }()
}

extension Shortcut.Modifiers {
    private static let appKit: [(Shortcut.Modifiers, NSEvent.ModifierFlags)] = [
        (.control, .control), (.option, .option), (.shift, .shift), (.command, .command), (.function, .function),
    ]

    /// The modifiers of an AppKit event that a shortcut tells apart; Caps Lock and the keypad flag are not among them
    init(_ flags: NSEvent.ModifierFlags) {
        self = Self.appKit.reduce(into: []) { modifiers, pair in
            if flags.contains(pair.1) {
                modifiers.insert(pair.0)
            }
        }
    }

    var flags: NSEvent.ModifierFlags {
        Self.appKit.reduce(into: []) { flags, pair in
            if contains(pair.0) {
                flags.insert(pair.1)
            }
        }
    }
}
