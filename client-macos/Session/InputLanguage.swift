import Carbon.HIToolbox
import Foundation

/// The language of the keyboard layout the Mac types with, as the helper takes it for input.layout
enum InputLanguage {
    /// macOS posts this when the user switches the input source, from the menu bar or with a shortcut
    static let changed = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    /// The language of the current input source: "ru", "en"; nil when the source names none
    static func current() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(property).takeUnretainedValue() as? [String] ?? []
        return first(of: languages)
    }

    /// The first language a source lists is the one it types; an empty one names nothing
    static func first(of languages: [String]) -> String? {
        languages.first { !$0.isEmpty }
    }
}

/// A distributed notification watched on the main thread for as long as the object lives
final class DistributedObservation: @unchecked Sendable {
    private let token: NSObjectProtocol

    @MainActor
    init(_ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
        token = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(token)
    }
}
