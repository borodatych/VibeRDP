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
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
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
    var remoteText = ""

    func offerClipboard(_ formats: [VRCClipboardFormat]) {
        offers.append(formats)
    }

    func provideClipboardData(_ format: VRCClipboardFormat, data: Data?) {
        answers.append(data)
    }

    func copyRemoteClipboard(_ format: VRCClipboardFormat, timeout: Duration) -> Data? {
        copies += 1
        return Data(remoteText.utf8)
    }
}
