import AppKit
import VibeRDPCore

/// The clipboard half of a session, as the bridge uses it
@MainActor
protocol ClipboardChannel: AnyObject {
    /// The Mac clipboard changed: the formats it offers now, none when it holds nothing the remote side takes
    func offerClipboard(_ formats: [VRCClipboardFormat])
    /// The answer to a paste on the remote computer; nil when the Mac clipboard no longer holds the format
    func provideClipboardData(_ format: VRCClipboardFormat, data: Data?)
    /// The remote clipboard in a format it offers, waiting for the remote computer up to the timeout
    /// nil when it has no such data or did not answer in time
    func copyRemoteClipboard(_ format: VRCClipboardFormat, timeout: Duration) -> Data?
}

/// Keeps the Mac clipboard and the clipboard of the remote computer in step for one session
///
/// macOS tells nobody that its clipboard changed, so the bridge reads the change count on a timer,
/// and a copy on the Mac reaches the remote side before the user can paste it there
/// Data moves only when the other side pastes: the remote side asks through the session,
/// the Mac through the data provider of the item that stands for the remote clipboard
/// The change count of that item is the bridge's own, so the remote clipboard never comes back to it as a Mac copy
@MainActor
final class ClipboardBridge: NSObject {
    /// How often the change count is read, in seconds: a copy goes over before the hand gets to the other window
    static let pollInterval: TimeInterval = 0.25
    /// How long a paste on the Mac waits for the remote computer
    static let copyTimeout: Duration = .seconds(10)
    /// An image may take megabytes, and a slow link needs longer for them than for text
    static let imageCopyTimeout: Duration = .seconds(60)
    /// The formats the bridge carries, in the order they are offered
    static let formats: [VRCClipboardFormat] = [.text, .html, .rtf, .image]
    /// HTML of the remote clipboard is UTF-8, and HTML without a declared charset the Mac reads as Latin-1:
    /// the declaration goes first, where the parser finds it before any other
    static let htmlCharset = Data(#"<meta charset="utf-8">"#.utf8)

    private let pasteboard: NSPasteboard
    private weak var channel: ClipboardChannel?
    private var timer: Timer?
    /// The change count the bridge has dealt with
    private var seenChangeCount: Int
    /// The change count of the item the bridge wrote for the remote clipboard, while it is the current one
    private var ownChangeCount: Int?
    /// The image of the remote clipboard once fetched: a paste may read it as PNG and as TIFF, and it comes over once
    private var remoteImage: Data?

    init(pasteboard: NSPasteboard = .general, channel: ClipboardChannel) {
        self.pasteboard = pasteboard
        self.channel = channel
        seenChangeCount = pasteboard.changeCount
    }

    /// Offers what the Mac clipboard holds now and starts watching it
    func start() {
        seenChangeCount = pasteboard.changeCount
        channel?.offerClipboard(Self.formats(of: pasteboard))
        // The common modes keep the timer running while a menu is open
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops watching; the item for the remote clipboard goes too, since nothing could fill it any more
    func stop() {
        timer?.invalidate()
        timer = nil
        if let ownChangeCount, pasteboard.changeCount == ownChangeCount {
            pasteboard.clearContents()
        }
        ownChangeCount = nil
    }

    /// A change the bridge did not make is a copy on the Mac: its formats go to the remote side
    func poll() {
        let count = pasteboard.changeCount
        guard count != seenChangeCount else { return }
        seenChangeCount = count
        guard count != ownChangeCount else { return }
        ownChangeCount = nil
        channel?.offerClipboard(Self.formats(of: pasteboard))
    }

    /// The remote clipboard changed: an item stands for it, and its data comes only when the Mac pastes
    /// A remote clipboard with nothing the Mac takes empties the Mac clipboard, so no stale copy gets pasted
    func remoteClipboardChanged(_ formats: [VRCClipboardFormat]) {
        remoteImage = nil
        pasteboard.clearContents()
        let types = formats.flatMap(Self.types(for:))
        if !types.isEmpty {
            let item = NSPasteboardItem()
            item.setDataProvider(self, forTypes: types)
            pasteboard.writeObjects([item])
        }
        ownChangeCount = pasteboard.changeCount
        seenChangeCount = pasteboard.changeCount
    }

    /// The remote computer pastes the Mac clipboard: the answer is what it holds now
    func dataRequested(_ format: VRCClipboardFormat) {
        channel?.provideClipboardData(format, data: Self.data(of: pasteboard, in: format))
    }

    /// What the remote side can take from the clipboard
    static func formats(of pasteboard: NSPasteboard) -> [VRCClipboardFormat] {
        formats.filter { pasteboard.availableType(from: types(for: $0)) != nil }
    }

    /// The pasteboard types that stand for a format of the core
    static func types(for format: VRCClipboardFormat) -> [NSPasteboard.PasteboardType] {
        switch format {
        case .text: [.string]
        case .html: [.html]
        case .rtf: [.rtf]
        // Screenshots and browsers write PNG, most other apps of the Mac only TIFF
        case .image: [.png, .tiff]
        }
    }

    /// The data of the clipboard in the form the core takes: text and HTML as UTF-8, RTF as it is, an image as PNG
    static func data(of pasteboard: NSPasteboard, in format: VRCClipboardFormat) -> Data? {
        switch format {
        case .text: pasteboard.string(forType: .string).map { Data($0.utf8) }
        case .html: pasteboard.data(forType: .html).flatMap(utf8)
        case .rtf: pasteboard.data(forType: .rtf)
        case .image: pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap(png)
        }
    }

    /// The first image of a TIFF as PNG
    private static func png(_ tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// A PNG as TIFF, for the apps of the Mac that read only TIFF
    private static func tiff(_ png: Data) -> Data? {
        NSBitmapImageRep(data: png)?.tiffRepresentation
    }

    /// HTML of the Mac is UTF-8 as a rule; one written as UTF-16 starts with a byte order mark and is converted
    private static func utf8(_ html: Data) -> Data? {
        let mark = html.prefix(2)
        guard mark == Data([0xFF, 0xFE]) || mark == Data([0xFE, 0xFF]) else { return html }
        return String(data: html, encoding: .utf16).map { Data($0.utf8) }
    }

    private static func format(of type: NSPasteboard.PasteboardType) -> VRCClipboardFormat? {
        formats.first { types(for: $0).contains(type) }
    }

    /// The Mac pastes the remote clipboard: its data comes over now, while the paste waits
    private func provide(_ item: NSPasteboardItem, type: NSPasteboard.PasteboardType) {
        guard let format = Self.format(of: type) else { return }
        if format == .image {
            provideImage(item, type: type)
            return
        }
        guard let data = channel?.copyRemoteClipboard(format, timeout: Self.copyTimeout) else { return }
        item.setData(format == .html ? Self.htmlCharset + data : data, forType: type)
    }

    /// The image comes over as PNG, once for both types
    private func provideImage(_ item: NSPasteboardItem, type: NSPasteboard.PasteboardType) {
        if remoteImage == nil {
            remoteImage = channel?.copyRemoteClipboard(.image, timeout: Self.imageCopyTimeout)
        }
        guard let png = remoteImage else { return }
        guard let data = type == .tiff ? Self.tiff(png) : png else { return }
        item.setData(data, forType: type)
    }
}

/// AppKit asks the provider on the main thread: when another app pastes, through the run loop,
/// and when this one reads the clipboard, within the read
extension ClipboardBridge: @MainActor NSPasteboardItemDataProvider {
    @MainActor
    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        provide(item, type: type)
    }

    @MainActor
    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}
