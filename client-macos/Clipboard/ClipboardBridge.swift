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
    /// Starts copying the files of the remote clipboard into a folder off the main thread, waiting up to the timeout
    /// for each answer of the remote computer; the copy reports its bytes and its end to progress
    func copyRemoteFiles(to folder: URL, timeout: Duration, progress: FileCopyProgress)
}

/// Keeps the Mac clipboard and the clipboard of the remote computer in step for one session
///
/// macOS tells nobody that its clipboard changed, so the bridge reads the change count on a timer,
/// and a copy on the Mac reaches the remote side before the user can paste it there
/// Data moves only when the other side pastes: the remote side asks through the session,
/// the Mac through the data provider of the item that stands for the remote clipboard
/// The change count of that item is the bridge's own, so the remote clipboard never comes back to it as a Mac copy
///
/// Files of the remote clipboard stand on the Mac as file URLs, one item for each name at the top of the copy:
/// Finder pastes only files that exist, so the first paste brings them all into a folder of the caches,
/// and the paste waits for them over a window with progress
@MainActor
final class ClipboardBridge: NSObject {
    /// How often the change count is read, in seconds: a copy goes over before the hand gets to the other window
    static let pollInterval: TimeInterval = 0.25
    /// How long a paste on the Mac waits for the remote computer
    static let copyTimeout: Duration = .seconds(10)
    /// An image may take megabytes, and a slow link needs longer for them than for text
    static let imageCopyTimeout: Duration = .seconds(60)
    /// How long a copy of files waits for each range of a file, a megabyte at a time
    static let fileRangeTimeout: Duration = .seconds(60)
    /// The formats the bridge carries, in the order they are offered
    static let formats: [VRCClipboardFormat] = [.text, .html, .rtf, .image, .files]
    /// HTML of the remote clipboard is UTF-8, and HTML without a declared charset the Mac reads as Latin-1:
    /// the declaration goes first, where the parser finds it before any other
    static let htmlCharset = Data(#"<meta charset="utf-8">"#.utf8)

    private let pasteboard: NSPasteboard
    private weak var channel: ClipboardChannel?
    private let waiter: FileCopyWaiter
    private let staging: FileStaging
    private var timer: Timer?
    /// Seconds between two looks at the change count: the settings give it, pollInterval by default
    private let interval: TimeInterval
    /// The change count the bridge has dealt with
    private var seenChangeCount: Int
    /// The change count of the item the bridge wrote for the remote clipboard, while it is the current one
    private var ownChangeCount: Int?
    /// The image of the remote clipboard once fetched: a paste may read it as PNG and as TIFF, and it comes over once
    private var remoteImage: Data?
    /// The name at the top of the remote copy each item of the Mac clipboard stands for
    private var remoteFileNames: [ObjectIdentifier: String] = [:]
    /// The folder the remote files came into, once a paste brought them
    private var remoteFilesFolder: URL?

    init(
        pasteboard: NSPasteboard = .general, channel: ClipboardChannel, waiter: FileCopyWaiter = FileCopyPanel(),
        staging: FileStaging = FileStaging(), interval: TimeInterval = ClipboardBridge.pollInterval
    ) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.channel = channel
        self.waiter = waiter
        self.staging = staging
        seenChangeCount = pasteboard.changeCount
    }

    /// Offers what the Mac clipboard holds now and starts watching it
    func start() {
        staging.removeStale()
        seenChangeCount = pasteboard.changeCount
        channel?.offerClipboard(Self.formats(of: pasteboard))
        // The common modes keep the timer running while a menu is open
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
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
        forgetRemoteFiles()
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
        forgetRemoteFiles()
        pasteboard.clearContents()
        let types = formats.filter { $0 != .files }.flatMap(Self.types(for:))
        // One item for each file, the other formats on the first: Finder takes one file URL from an item
        let names = formats.contains(.files) ? fetchRemoteFileNames() : []
        var items: [NSPasteboardItem] = []
        for name in names {
            let item = NSPasteboardItem()
            item.setDataProvider(self, forTypes: items.isEmpty ? [.fileURL] + types : [.fileURL])
            remoteFileNames[ObjectIdentifier(item)] = name
            items.append(item)
        }
        if items.isEmpty && !types.isEmpty {
            let item = NSPasteboardItem()
            item.setDataProvider(self, forTypes: types)
            items.append(item)
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
        ownChangeCount = pasteboard.changeCount
        seenChangeCount = pasteboard.changeCount
    }

    /// The remote computer pastes the Mac clipboard: the answer is what it holds now
    func dataRequested(_ format: VRCClipboardFormat) {
        channel?.provideClipboardData(format, data: Self.data(of: pasteboard, in: format))
    }

    /// What the remote side can take from the clipboard
    /// Finder puts the icons of copied files beside them as an image: with files, the image is not offered
    static func formats(of pasteboard: NSPasteboard) -> [VRCClipboardFormat] {
        let files = !fileURLs(in: pasteboard).isEmpty
        return formats.filter { format in
            switch format {
            case .files: files
            case .image: !files && pasteboard.availableType(from: types(for: format)) != nil
            default: pasteboard.availableType(from: types(for: format)) != nil
            }
        }
    }

    /// The files and folders a copy on the Mac holds
    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// The pasteboard types that stand for a format of the core
    static func types(for format: VRCClipboardFormat) -> [NSPasteboard.PasteboardType] {
        switch format {
        case .text: [.string]
        case .html: [.html]
        case .rtf: [.rtf]
        // Screenshots and browsers write PNG, most other apps of the Mac only TIFF
        case .image: [.png, .tiff]
        case .files: [.fileURL]
        }
    }

    /// The data of the clipboard in the form the core takes: text and HTML as UTF-8, RTF as it is, an image as PNG,
    /// files as their paths
    static func data(of pasteboard: NSPasteboard, in format: VRCClipboardFormat) -> Data? {
        switch format {
        case .text: pasteboard.string(forType: .string).map { Data($0.utf8) }
        case .html: pasteboard.data(forType: .html).flatMap(utf8)
        case .rtf: pasteboard.data(forType: .rtf)
        case .image: pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap(png)
        case .files: paths(of: fileURLs(in: pasteboard))
        }
    }

    /// The paths of files, each ending with a zero byte, nil for none: the core reads the files itself
    private static func paths(of urls: [URL]) -> Data? {
        urls.isEmpty ? nil : Data(urls.map { $0.path(percentEncoded: false) + "\0" }.joined().utf8)
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
        if format == .files {
            provideFile(item)
            return
        }
        if format == .image {
            provideImage(item, type: type)
            return
        }
        guard let data = channel?.copyRemoteClipboard(format, timeout: Self.copyTimeout) else { return }
        item.setData(format == .html ? Self.htmlCharset + data : data, forType: type)
    }

    /// The names at the top of the remote copy, each ending with a zero byte in the answer of the core
    private func fetchRemoteFileNames() -> [String] {
        guard let data = channel?.copyRemoteClipboard(.files, timeout: Self.copyTimeout) else { return [] }
        return data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    private func forgetRemoteFiles() {
        remoteFileNames = [:]
        if let remoteFilesFolder {
            staging.remove(remoteFilesFolder)
        }
        remoteFilesFolder = nil
    }

    /// The Mac pastes a remote file: the first paste brings all of them, and each item then names its own
    private func provideFile(_ item: NSPasteboardItem) {
        guard let name = remoteFileNames[ObjectIdentifier(item)], let folder = copyRemoteFiles() else { return }
        item.setString(folder.appending(path: name).absoluteString, forType: .fileURL)
    }

    /// Brings the remote files into a fresh folder while the paste waits; nil when the copy did not complete
    private func copyRemoteFiles() -> URL? {
        if let remoteFilesFolder {
            return remoteFilesFolder
        }
        guard let channel, let folder = staging.makeFolder() else { return nil }
        let progress = FileCopyProgress()
        channel.copyRemoteFiles(to: folder, timeout: Self.fileRangeTimeout, progress: progress)
        waiter.wait(for: progress)
        guard progress.result == .OK else {
            staging.remove(folder)
            if progress.result != .cancelled {
                waiter.copyFailed()
            }
            return nil
        }
        remoteFilesFolder = folder
        return folder
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
