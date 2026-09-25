import AppKit
import VibeRDPCore
import XCTest

@testable import VibeRDP

/// The bridge between a pasteboard and the clipboard half of a session, on a private pasteboard:
/// the general one of this Mac is never touched
@MainActor
final class ClipboardBridgeTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var channel: RecordingChannel!
    private var waiter: ImmediateWaiter!
    private var folder: URL!
    private var bridge: ClipboardBridge!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("tech.vibebrains.viberdp.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        channel = RecordingChannel()
        waiter = ImmediateWaiter()
        folder = FileManager.default.temporaryDirectory.appending(path: "viberdp-bridge-\(UUID().uuidString)")
        bridge = ClipboardBridge(
            pasteboard: pasteboard, channel: channel, waiter: waiter,
            staging: FileStaging(root: folder.appending(path: "staging")))
    }

    override func tearDown() async throws {
        bridge.stop()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: folder)
    }

    /// The text the Mac holds when the session starts goes over as an offer at once
    func testStartOffersWhatTheMacHolds() {
        pasteboard.setString("hello", forType: .string)
        bridge.start()
        XCTAssertEqual(channel.offers, [[.text]])
    }

    /// Every copy on the Mac is an offer, one without text an empty one; no change, no offer
    func testCopiesOnTheMacAreOffered() {
        bridge.start()
        XCTAssertEqual(channel.offers, [[]])

        pasteboard.clearContents()
        pasteboard.setString("new", forType: .string)
        bridge.poll()
        bridge.poll()
        XCTAssertEqual(channel.offers, [[], [.text]])

        pasteboard.clearContents()
        pasteboard.setData(Data("x".utf8), forType: .pdf)
        bridge.poll()
        XCTAssertEqual(channel.offers, [[], [.text], []])
    }

    /// The remote clipboard stands on the Mac as an item whose data comes only when something pastes it
    func testRemoteTextComesWhenPasted() {
        bridge.start()
        channel.remoteText = "from Windows"
        bridge.remoteClipboardChanged([.text])
        XCTAssertEqual(channel.copies, 0)

        XCTAssertEqual(pasteboard.string(forType: .string), "from Windows")
        XCTAssertEqual(channel.copies, 1)
    }

    /// The item for the remote clipboard is the bridge's own change: it never goes back as a Mac copy
    func testRemoteClipboardIsNotEchoed() {
        bridge.start()
        bridge.remoteClipboardChanged([.text])
        bridge.poll()
        XCTAssertEqual(channel.offers, [[]])

        // The next copy on the Mac is the user's again
        pasteboard.clearContents()
        pasteboard.setString("mine", forType: .string)
        bridge.poll()
        XCTAssertEqual(channel.offers, [[], [.text]])
    }

    /// A remote clipboard with nothing the Mac takes empties the Mac clipboard: no stale copy gets pasted
    func testRemoteClipboardWithoutTextEmptiesTheMac() {
        pasteboard.setString("old", forType: .string)
        bridge.start()
        bridge.remoteClipboardChanged([])
        XCTAssertNil(pasteboard.string(forType: .string))
        bridge.poll()
        XCTAssertEqual(channel.offers, [[.text]])
    }

    /// Windows pastes: the answer is the text the Mac holds, or none when it holds no text any more
    func testRemotePasteGetsTheMacText() {
        pasteboard.setString("mac text", forType: .string)
        bridge.dataRequested(.text)
        pasteboard.clearContents()
        bridge.dataRequested(.text)
        XCTAssertEqual(channel.answers, [Data("mac text".utf8), nil])
    }

    /// HTML and RTF go over with the text; the remote side gets each in the form the core takes
    func testRichFormatsAreOfferedAndAnswered() {
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setData(Data("<b>Жирный</b>".utf8), forType: .html)
        item.setData(Data(#"{\rtf1 x}"#.utf8), forType: .rtf)
        pasteboard.writeObjects([item])
        bridge.start()
        XCTAssertEqual(channel.offers, [[.text, .html, .rtf]])

        bridge.dataRequested(.html)
        bridge.dataRequested(.rtf)
        XCTAssertEqual(channel.answers, [Data("<b>Жирный</b>".utf8), Data(#"{\rtf1 x}"#.utf8)])
    }

    /// HTML written as UTF-16 reaches the core as UTF-8
    func testHtmlInUtf16IsConverted() throws {
        let utf16 = try XCTUnwrap("<i>ю</i>".data(using: .utf16))
        pasteboard.setData(utf16, forType: .html)
        bridge.dataRequested(.html)
        XCTAssertEqual(channel.answers, [Data("<i>ю</i>".utf8)])
    }

    /// Remote HTML declares its charset for the Mac, which reads undeclared HTML as Latin-1
    func testRemoteHtmlDeclaresItsCharset() throws {
        bridge.start()
        channel.remoteText = "<p>Привет</p>"
        bridge.remoteClipboardChanged([.text, .html])
        let html = try XCTUnwrap(pasteboard.data(forType: .html))
        XCTAssertEqual(String(data: html, encoding: .utf8), #"<meta charset="utf-8"><p>Привет</p>"#)
        let text = try NSAttributedString(
            data: html, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
        XCTAssertEqual(text.string.trimmingCharacters(in: .whitespacesAndNewlines), "Привет")
    }

    /// An image of the Mac goes over as PNG, whether the app that copied it wrote PNG or only TIFF
    func testImagesGoOverAsPng() throws {
        pasteboard.setData(TestImage.tiff, forType: .tiff)
        bridge.start()
        XCTAssertEqual(channel.offers, [[.image]])
        bridge.dataRequested(.image)

        pasteboard.clearContents()
        pasteboard.setData(TestImage.png, forType: .png)
        bridge.dataRequested(.image)

        XCTAssertEqual(channel.answers.count, 2)
        for answer in channel.answers {
            let png = try XCTUnwrap(answer)
            XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
            XCTAssertTrue(TestImage.matches(png))
        }
    }

    /// The remote image stands on the Mac as PNG and as TIFF, and comes over once whichever the paste reads
    func testRemoteImageComesOnceForBothTypes() throws {
        bridge.start()
        channel.remoteData = TestImage.png
        bridge.remoteClipboardChanged([.image])

        XCTAssertTrue(TestImage.matches(try XCTUnwrap(pasteboard.data(forType: .tiff))))
        XCTAssertEqual(pasteboard.data(forType: .png), TestImage.png)
        XCTAssertEqual(channel.copies, 1)
        XCTAssertEqual(channel.timeouts, [ClipboardBridge.imageCopyTimeout])
    }

    /// Files of the Mac go over as their paths; the icon Finder puts beside them is not offered as an image
    func testFilesGoOverAsPaths() throws {
        let first = try makeFile("a.txt", "a")
        let second = try makeFile("Папка/b.txt", "b").deletingLastPathComponent()
        let item = NSPasteboardItem()
        item.setString(first.absoluteString, forType: .fileURL)
        item.setData(TestImage.tiff, forType: .tiff)
        pasteboard.writeObjects([item, second as NSURL])
        bridge.start()
        let offer = try XCTUnwrap(channel.offers.last)
        XCTAssertTrue(offer.contains(.files))
        XCTAssertFalse(offer.contains(.image))

        bridge.dataRequested(.files)
        let paths = first.path(percentEncoded: false) + "\0" + second.path(percentEncoded: false) + "\0"
        XCTAssertEqual(channel.answers, [Data(paths.utf8)])
    }

    /// Remote files stand on the Mac as one item each; the first paste brings them all, later ones take them
    func testRemoteFilesComeOnPaste() throws {
        bridge.start()
        channel.remoteText = "names too"
        channel.remoteNames = Data("Папка\0b.txt\0".utf8)
        channel.remoteFiles = ["Папка/a.txt": "a", "b.txt": "b"]
        bridge.remoteClipboardChanged([.text, .files])
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
        XCTAssertEqual(channel.fileCopies, 0)

        let urls = try XCTUnwrap(
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Папка", "b.txt"])
        XCTAssertEqual(try String(contentsOf: urls[0].appending(path: "a.txt"), encoding: .utf8), "a")
        XCTAssertEqual(try String(contentsOf: urls[1], encoding: .utf8), "b")
        XCTAssertEqual(pasteboard.string(forType: .string), "names too")
        XCTAssertEqual(channel.fileCopies, 1)
        XCTAssertEqual(waiter.waits, 1)

        // A new remote copy takes the old files away
        bridge.remoteClipboardChanged([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[1].path(percentEncoded: false)))
    }

    /// A copy that fails leaves no files and tells the user; a cancelled one only leaves no files
    func testFailedFileCopy() throws {
        bridge.start()
        channel.remoteNames = Data("b.txt\0".utf8)
        channel.remoteFiles = ["b.txt": "b"]
        channel.fileResult = .failure
        bridge.remoteClipboardChanged([.files])
        XCTAssertNil(pasteboard.string(forType: .fileURL))
        XCTAssertEqual(waiter.failures, 1)

        channel.fileResult = .cancelled
        bridge.remoteClipboardChanged([.files])
        XCTAssertNil(pasteboard.string(forType: .fileURL))
        XCTAssertEqual(waiter.failures, 1)
        let staged = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "staging").path)
        XCTAssertEqual(staged, [])
    }

    /// A file of the test folder with this text, and the folders on its way
    private func makeFile(_ name: String, _ text: String) throws -> URL {
        let url = folder.appending(path: "mac").appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// When the session ends, the item that stood for the remote clipboard goes, a copy of the user stays
    func testStopRemovesOnlyTheRemoteItem() {
        bridge.start()
        bridge.remoteClipboardChanged([.text])
        bridge.stop()
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)

        pasteboard.clearContents()
        pasteboard.setString("user", forType: .string)
        bridge.start()
        bridge.stop()
        XCTAssertEqual(pasteboard.string(forType: .string), "user")
    }
}

/// Records what the bridge sends and plays the remote side of a copy
@MainActor
private final class RecordingChannel: ClipboardChannel {
    private(set) var offers: [[VRCClipboardFormat]] = []
    private(set) var answers: [Data?] = []
    private(set) var copies = 0
    private(set) var timeouts: [Duration] = []
    private(set) var fileCopies = 0
    var remoteText = ""
    /// Bytes of the remote side that are not text; the text stands in when they are nil
    var remoteData: Data?
    /// The names at the top of the remote files, and the files by their paths with their text
    var remoteNames: Data?
    var remoteFiles: [String: String] = [:]
    var fileResult: VRCResult = .OK

    func offerClipboard(_ formats: [VRCClipboardFormat]) {
        offers.append(formats)
    }

    func provideClipboardData(_ format: VRCClipboardFormat, data: Data?) {
        answers.append(data)
    }

    func copyRemoteClipboard(_ format: VRCClipboardFormat, timeout: Duration) -> Data? {
        copies += 1
        timeouts.append(timeout)
        if format == .files {
            return remoteNames
        }
        return remoteData ?? Data(remoteText.utf8)
    }

    /// The files come at once, before the wait starts, as a fast copy does
    func copyRemoteFiles(to folder: URL, timeout: Duration, progress: FileCopyProgress) {
        fileCopies += 1
        for (name, text) in remoteFiles {
            let url = folder.appending(path: name)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
        progress.finish(fileResult)
    }
}

/// Waits for nothing: the recording channel ends its copies before the wait starts
@MainActor
private final class ImmediateWaiter: FileCopyWaiter {
    private(set) var waits = 0
    private(set) var failures = 0

    func wait(for progress: FileCopyProgress) {
        waits += 1
        XCTAssertNotNil(progress.result, "the recording channel finishes before the wait")
    }

    func copyFailed() {
        failures += 1
    }
}
