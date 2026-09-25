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
    private var bridge: ClipboardBridge!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("tech.vibebrains.viberdp.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        channel = RecordingChannel()
        bridge = ClipboardBridge(pasteboard: pasteboard, channel: channel)
    }

    override func tearDown() async throws {
        bridge.stop()
        pasteboard.releaseGlobally()
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
    var remoteText = ""
    /// Bytes of the remote side that are not text; the text stands in when they are nil
    var remoteData: Data?

    func offerClipboard(_ formats: [VRCClipboardFormat]) {
        offers.append(formats)
    }

    func provideClipboardData(_ format: VRCClipboardFormat, data: Data?) {
        answers.append(data)
    }

    func copyRemoteClipboard(_ format: VRCClipboardFormat, timeout: Duration) -> Data? {
        copies += 1
        timeouts.append(timeout)
        return remoteData ?? Data(remoteText.utf8)
    }
}
