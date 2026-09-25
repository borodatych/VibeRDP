import Carbon.HIToolbox

/// Turns the keys of the Mac into keys of the PC keyboard, or leaves them to the Mac
/// A combination the Mac keeps goes to the app with its release and repeats, so Windows never sees half of it
struct KeyboardTranslator {
    /// A key event of the Mac, stripped of AppKit
    enum Event: Equatable {
        case down(keyCode: UInt16, modifiers: Shortcut.Modifiers, isRepeat: Bool)
        case up(keyCode: UInt16)
        /// A modifier went down or up; Caps Lock reports each change of its state
        case modifier(keyCode: UInt16, down: Bool)
    }

    enum Action: Equatable {
        case send(key: UInt16, pressed: Bool, repeat: Bool)
        /// The event goes on to AppKit: menus and the system answer it
        case passToMac
    }

    /// Keys whose press the Mac took: their repeats and release follow it there
    private var keptOnMac: Set<UInt16> = []

    mutating func translate(_ event: Event, settings: KeyboardSettings) -> [Action] {
        switch event {
        case .down(let keyCode, let modifiers, let isRepeat):
            if keptOnMac.contains(keyCode) {
                return [.passToMac]
            }
            if let shortcut = Shortcut(keyCode: keyCode, modifiers: modifiers), settings.keepsOnMac(shortcut) {
                keptOnMac.insert(keyCode)
                return [.passToMac]
            }
            return KeyCodeMap.scanCode(of: keyCode, iso: settings.isoKeyboard).map {
                [.send(key: $0, pressed: true, repeat: isRepeat)]
            } ?? []
        case .up(let keyCode):
            if keptOnMac.remove(keyCode) != nil {
                return [.passToMac]
            }
            return KeyCodeMap.scanCode(of: keyCode, iso: settings.isoKeyboard).map {
                [.send(key: $0, pressed: false, repeat: false)]
            } ?? []
        case .modifier(let keyCode, let down):
            // macOS reports only the new state of Caps Lock, and every change is one press of the key
            if keyCode == UInt16(kVK_CapsLock), let key = KeyCodeMap.scanCode(of: keyCode, iso: settings.isoKeyboard) {
                return [.send(key: key, pressed: true, repeat: false), .send(key: key, pressed: false, repeat: false)]
            }
            if let modifier = MacModifier(keyCode: keyCode) {
                let key = settings.target(of: modifier).scanCode(right: modifier.isRight)
                return [.send(key: key, pressed: down, repeat: false)]
            }
            // Shift goes as it is; fn has no PC key
            return KeyCodeMap.scanCode(of: keyCode, iso: settings.isoKeyboard).map {
                [.send(key: $0, pressed: down, repeat: false)]
            } ?? []
        }
    }

    /// The keyboard left the desktop: a release still on its way belongs to nothing now
    mutating func reset() {
        keptOnMac = []
    }
}
