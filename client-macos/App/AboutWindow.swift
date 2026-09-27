import AppKit
import SwiftUI

/// The About window: the icon, the name, the version once, and the donation code whole, without scrolling
/// The panel of the system scrolls its credits in a box of its own height and repeats the version as the build
@MainActor
final class AboutWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView())
        window.setContentSize(window.contentView?.fittingSize ?? .zero)
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

private struct AboutView: View {
    static let iconSide: CGFloat = 96
    /// Large enough for a phone camera from the other side of the desk
    static let codeSide: CGFloat = 180
    static let width: CGFloat = 300

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Self.iconSide, height: Self.iconSide)
            Text(AppDelegate.appName)
                .font(.title2.bold())
            Text(Localization.text(.aboutVersion, ["version": AppDelegate.appVersion]))
                .foregroundStyle(.secondary)
            Text(Localization.text(.aboutDonate))
                .padding(.top, 8)
            // The code alone, cut from the picture of the bank without the name and the contract
            Image("Donate")
                .resizable()
                .interpolation(.none)
                .frame(width: Self.codeSide, height: Self.codeSide)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.top, 28)
        .padding([.horizontal, .bottom], 24)
        .frame(width: Self.width)
    }
}
