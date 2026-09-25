import AppKit
import Carbon.HIToolbox

/// A button that records a key combination: click it, then press the combination
/// While it records, it takes every key of its window, so ⌘Q and the like are recorded instead of acted on
@MainActor
final class ShortcutField: NSButton {
    /// The recorded combination, or nil when ⌫ cleared it
    var onRecord: ((Shortcut?) -> Void)?

    /// What the button says without a combination
    var placeholder = Localization.text(.shortcutNone) {
        didSet { updateTitle() }
    }

    var shortcut: Shortcut? {
        didSet { updateTitle() }
    }

    private(set) var isRecording = false
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the field is built in code")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        stopRecording()
    }

    /// One key event while recording, true when the field took it: a combination ends it, ⎋ cancels it, ⌫ records none
    /// Modifier changes and keys without ⌃, ⌥, ⌘ or fn are swallowed, and the recording goes on
    func takesKey(_ event: NSEvent) -> Bool {
        guard isRecording, event.window === window else { return false }
        guard event.type == .keyDown else { return true }

        let modifiers = Shortcut.Modifiers(event.modifierFlags)
        if modifiers.isEmpty && event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
        } else if modifiers.isEmpty && event.keyCode == UInt16(kVK_Delete) {
            stopRecording()
            onRecord?(nil)
        } else if let recorded = Shortcut(keyCode: event.keyCode, modifiers: modifiers) {
            stopRecording()
            onRecord?(recorded)
        }
        return true
    }

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording()
            return
        }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let taken = MainActor.assumeIsolated { self?.takesKey(event) ?? false }
            return taken ? nil : event
        }
        // Keys typed in another window are not meant for this field
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
        updateTitle()
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
        resignObserver.map(NotificationCenter.default.removeObserver)
        resignObserver = nil
        updateTitle()
    }

    private func updateTitle() {
        title = isRecording ? Localization.text(.shortcutRecording) : shortcut?.displayName ?? placeholder
    }
}
