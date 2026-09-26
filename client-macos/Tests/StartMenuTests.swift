import AppKit
import XCTest

@testable import VibeRDP

/// The Start menu of the host: the model from the messages of the helper, and the menu of the Mac built from it
@MainActor
final class StartMenuTests: XCTestCase {
    private func item(_ id: String, _ name: String, _ folder: String) -> MessagePackValue {
        .map([("id", .string(id)), ("name", .string(name)), ("folder", .string(folder))])
    }

    private var apps: MessagePackValue {
        .map([
            ("type", .string("apps")), ("seq", .uint(1)),
            ("items", .array([
                item("user/Excel.lnk", "Excel", ""),
                item("common/Accessories/Notepad.lnk", "Notepad", "Accessories"),
                item("common/Accessories/System Tools/Character Map.lnk", "Character Map", "Accessories/System Tools"),
            ])),
        ])
    }

    func testModelBuildsTheTreeAndKeepsIcons() {
        var model = RemoteApps()
        XCTAssertTrue(model.apply(apps))
        XCTAssertTrue(model.apply(.map([
            ("type", .string("app.icon")), ("id", .string("user/Excel.lnk")), ("png", .binary(Data([1]))),
        ])))
        XCTAssertFalse(model.apply(.map([("type", .string("window.destroy")), ("id", .uint(1))])))
        let tree = model.tree
        XCTAssertEqual(tree.apps.map(\.name), ["Excel"])
        XCTAssertEqual(tree.folders.map(\.name), ["Accessories"])
        XCTAssertEqual(tree.folders[0].apps.map(\.name), ["Notepad"])
        XCTAssertEqual(tree.folders[0].folders[0].apps.map(\.name), ["Character Map"])
        XCTAssertTrue(model.apply(apps), "a new list keeps the icons of the programs it still has")
        XCTAssertEqual(model.apps.first { $0.id == "user/Excel.lnk" }?.icon, Data([1]))
    }

    func testLinkAsksOnlyWhenReady() {
        var link = SeamLink(agent: "VibeRDP test", capabilities: ["seam"])
        XCTAssertNil(link.appsRequest())
        _ = link.opened(at: Date())
        let hello = MessagePack.encode(.map([
            ("type", .string("hello")), ("version", .uint(1)), ("capabilities", .array([.string("launcher")])),
        ]))
        _ = link.received(hello, at: Date())
        XCTAssertEqual(link.appsRequest(), .map([("type", .string("apps.request")), ("seq", .uint(1))]))
        XCTAssertEqual(
            link.launch("user/Excel.lnk"),
            .map([("type", .string("launch")), ("seq", .uint(2)), ("id", .string("user/Excel.lnk"))]))
    }

    func testMenuShowsFoldersAndLaunches() {
        let menu = NSMenu()
        let holder = NSMenuItem()
        let start = StartMenu(menu: menu, holder: holder)
        XCTAssertTrue(holder.isHidden)
        var model = RemoteApps()
        _ = model.apply(apps)
        start.show(model)
        XCTAssertFalse(holder.isHidden)
        var launched: [String] = []
        start.onLaunch = { launched.append($0) }
        start.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(\.title), ["Accessories", "Excel"])
        let notepad = menu.items[0].submenu?.items.last
        XCTAssertEqual(notepad?.title, "Notepad")
        if let notepad, let action = notepad.action {
            _ = (notepad.target as AnyObject).perform(action, with: notepad)
        }
        XCTAssertEqual(launched, ["common/Accessories/Notepad.lnk"])
        start.show(nil)
        XCTAssertTrue(holder.isHidden)
    }
}
