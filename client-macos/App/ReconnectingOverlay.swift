import AppKit

/// Over the frozen desktop while the connection is being restored: what happens, which attempt, and a way out
/// Lying on top, it takes the clicks, and the desktop under it gets none
@MainActor
final class ReconnectingOverlay: NSView {
    static let spacing: CGFloat = 12
    /// Dark enough to read white text over any desktop, light enough to show the desktop is still there
    static let dimming: CGFloat = 0.6
    static let secondaryTextOpacity: CGFloat = 0.8

    let titleLabel = NSTextField(labelWithString: "")
    let attemptLabel = NSTextField(labelWithString: "")
    let disconnectButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let onDisconnect: () -> Void

    init(host: String, onDisconnect: @escaping () -> Void) {
        self.onDisconnect = onDisconnect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.dimming).cgColor

        spinner.style = .spinning
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.startAnimation(nil)
        titleLabel.stringValue = Localization.text(.connectionStatusReconnecting, ["host": host])
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        titleLabel.textColor = .white
        attemptLabel.textColor = NSColor.white.withAlphaComponent(Self.secondaryTextOpacity)
        disconnectButton.title = Localization.text(.connectionActionDisconnect)
        disconnectButton.bezelStyle = .push
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnect)

        let stack = NSStackView(views: [spinner, titleLabel, attemptLabel, disconnectButton])
        stack.orientation = .vertical
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("the view is built in code")
    }

    /// The attempt about to start
    func show(attempt: UInt32, of maxAttempts: UInt32) {
        attemptLabel.stringValue = Localization.text(
            .connectionReconnectingAttempt, ["attempt": String(attempt), "count": String(maxAttempts)])
    }

    @objc private func disconnect() {
        onDisconnect()
    }
}
