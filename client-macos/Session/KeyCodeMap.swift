import Carbon.HIToolbox
import VibeRDPCore

/// Keys of the Mac keyboard as the keys of a PC keyboard in the same place: scan codes of set 1, as RDP carries them
/// The key codes are the kVK names of HIToolbox Events.h, the scan codes those of FreeRDP include/freerdp/scancode.h
/// The server turns a scan code into a character with its own layout, so the Mac layout plays no part
enum KeyCodeMap {
    /// The PC key in the place of a Mac key; nil for fn and for keys a PC keyboard lacks
    /// ⌃, ⌥ and ⌘ are not here: they become the PC modifiers the settings choose, see WindowsModifier
    /// On an ISO keyboard macOS reports the key left of 1 as kVK_ISO_Section and the one right of the left Shift
    /// as kVK_ANSI_Grave, so the two change places
    static func scanCode(of keyCode: UInt16, iso: Bool) -> UInt16? {
        switch Int(keyCode) {
        case kVK_ISO_Section: iso ? topLeft : besideLeftShift
        case kVK_ANSI_Grave: iso ? besideLeftShift : topLeft
        default: table[keyCode]
        }
    }

    /// The key left of 1, grave on a US layout, and the extra key of ISO keyboards between the left Shift and Z
    private static let topLeft: UInt16 = 0x29
    private static let besideLeftShift: UInt16 = 0x56

    private static let extended = UInt16(VRC_KEY_EXTENDED)

    private static let table: [UInt16: UInt16] = {
        let keys: [(Int, UInt16)] = [
            (kVK_Escape, 0x01),
            (kVK_ANSI_1, 0x02), (kVK_ANSI_2, 0x03), (kVK_ANSI_3, 0x04), (kVK_ANSI_4, 0x05), (kVK_ANSI_5, 0x06),
            (kVK_ANSI_6, 0x07), (kVK_ANSI_7, 0x08), (kVK_ANSI_8, 0x09), (kVK_ANSI_9, 0x0A), (kVK_ANSI_0, 0x0B),
            (kVK_ANSI_Minus, 0x0C), (kVK_ANSI_Equal, 0x0D), (kVK_Delete, 0x0E), (kVK_Tab, 0x0F),
            (kVK_ANSI_Q, 0x10), (kVK_ANSI_W, 0x11), (kVK_ANSI_E, 0x12), (kVK_ANSI_R, 0x13), (kVK_ANSI_T, 0x14),
            (kVK_ANSI_Y, 0x15), (kVK_ANSI_U, 0x16), (kVK_ANSI_I, 0x17), (kVK_ANSI_O, 0x18), (kVK_ANSI_P, 0x19),
            (kVK_ANSI_LeftBracket, 0x1A), (kVK_ANSI_RightBracket, 0x1B), (kVK_Return, 0x1C),
            (kVK_ANSI_A, 0x1E), (kVK_ANSI_S, 0x1F), (kVK_ANSI_D, 0x20), (kVK_ANSI_F, 0x21), (kVK_ANSI_G, 0x22),
            (kVK_ANSI_H, 0x23), (kVK_ANSI_J, 0x24), (kVK_ANSI_K, 0x25), (kVK_ANSI_L, 0x26),
            (kVK_ANSI_Semicolon, 0x27), (kVK_ANSI_Quote, 0x28), (kVK_Shift, 0x2A), (kVK_ANSI_Backslash, 0x2B),
            (kVK_ANSI_Z, 0x2C), (kVK_ANSI_X, 0x2D), (kVK_ANSI_C, 0x2E), (kVK_ANSI_V, 0x2F), (kVK_ANSI_B, 0x30),
            (kVK_ANSI_N, 0x31), (kVK_ANSI_M, 0x32), (kVK_ANSI_Comma, 0x33), (kVK_ANSI_Period, 0x34),
            (kVK_ANSI_Slash, 0x35), (kVK_RightShift, 0x36), (kVK_ANSI_KeypadMultiply, 0x37),
            (kVK_Space, 0x39), (kVK_CapsLock, 0x3A),
            (kVK_F1, 0x3B), (kVK_F2, 0x3C), (kVK_F3, 0x3D), (kVK_F4, 0x3E), (kVK_F5, 0x3F), (kVK_F6, 0x40),
            (kVK_F7, 0x41), (kVK_F8, 0x42), (kVK_F9, 0x43), (kVK_F10, 0x44), (kVK_F11, 0x57), (kVK_F12, 0x58),
            // Clear sits where a PC keypad has Num Lock
            (kVK_ANSI_KeypadClear, 0x45),
            (kVK_ANSI_Keypad7, 0x47), (kVK_ANSI_Keypad8, 0x48), (kVK_ANSI_Keypad9, 0x49),
            (kVK_ANSI_KeypadMinus, 0x4A), (kVK_ANSI_Keypad4, 0x4B), (kVK_ANSI_Keypad5, 0x4C),
            (kVK_ANSI_Keypad6, 0x4D), (kVK_ANSI_KeypadPlus, 0x4E), (kVK_ANSI_Keypad1, 0x4F),
            (kVK_ANSI_Keypad2, 0x50), (kVK_ANSI_Keypad3, 0x51), (kVK_ANSI_Keypad0, 0x52),
            (kVK_ANSI_KeypadDecimal, 0x53),
            // FreeRDP names no keypad equals: 0x59 is its code in the USB HID to PS/2 table of Microsoft
            (kVK_ANSI_KeypadEquals, 0x59),
            // F13 to F15 of the Apple extended keyboard stand over the navigation keys, as Print Screen,
            // Scroll Lock and Pause do on a PC; F16 to F20 have no such place and stay function keys
            (kVK_F13, extended | 0x37), (kVK_F14, 0x46), (kVK_F15, UInt16(VRC_KEY_PAUSE)),
            (kVK_F16, 0x67), (kVK_F17, 0x68), (kVK_F18, 0x69), (kVK_F19, 0x6A), (kVK_F20, 0x6B),
            (kVK_JIS_Underscore, 0x73), (kVK_JIS_Yen, 0x7D), (kVK_JIS_KeypadComma, 0x7E),
            (kVK_ANSI_KeypadEnter, extended | 0x1C), (kVK_ANSI_KeypadDivide, extended | 0x35),
            (kVK_Home, extended | 0x47), (kVK_UpArrow, extended | 0x48), (kVK_PageUp, extended | 0x49),
            (kVK_LeftArrow, extended | 0x4B), (kVK_RightArrow, extended | 0x4D), (kVK_End, extended | 0x4F),
            (kVK_DownArrow, extended | 0x50), (kVK_PageDown, extended | 0x51),
            // Help sits where a PC keyboard has Insert
            (kVK_Help, extended | 0x52), (kVK_ForwardDelete, extended | 0x53),
            (kVK_ContextualMenu, extended | 0x5D),
            (kVK_Mute, extended | 0x20), (kVK_VolumeDown, extended | 0x2E), (kVK_VolumeUp, extended | 0x30),
        ]
        return Dictionary(uniqueKeysWithValues: keys.map { (UInt16($0.0), $0.1) })
    }()
}
