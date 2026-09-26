import AppKit
import SwiftUI
import VibeRDPCore
import XCTest

@testable import VibeRDP

/// The saved profiles: kept in the defaults, each with its password in the store
@MainActor
final class ProfileStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testProfilesSurviveAndKeepTheirOrder() {
        let passwords = MemoryPasswordStore()
        let store = ProfileStore(defaults: defaults, passwords: passwords)
        let office = ConnectionProfile(name: "Офис", address: "win.corp:3390", username: "CORP\\alice")
        let lab = ConnectionProfile(address: "10.0.0.5", remembersPassword: false, keyboard: .pc)
        store.add(office)
        store.add(lab)
        var renamed = office
        renamed.name = "Офис 2"
        store.update(renamed)
        store.update(ConnectionProfile(address: "unknown"))

        let reopened = ProfileStore(defaults: defaults, passwords: passwords)
        XCTAssertEqual(reopened.profiles, [renamed, lab])
        XCTAssertEqual(reopened.profile(lab.id)?.keyboard, .pc)
        XCTAssertNil(reopened.profile(UUID()))
    }

    /// A profile that goes takes its saved passwords with it, the gateway's too
    func testDeleteForgetsThePasswords() {
        let passwords = MemoryPasswordStore()
        let store = ProfileStore(defaults: defaults, passwords: passwords)
        let profile = ConnectionProfile(address: "win")
        store.add(profile)
        XCTAssertEqual(passwords.setPassword("secret", for: profile.id, kind: .server, label: "x"), errSecSuccess)
        XCTAssertEqual(passwords.setPassword("gate", for: profile.id, kind: .gateway, label: "x"), errSecSuccess)
        store.delete(profile.id)
        XCTAssertEqual(store.profiles, [])
        XCTAssertTrue(passwords.passwords.isEmpty)
    }

    /// A profile saved without the gateway settings reads with their defaults: a direct connection
    func testProfileWithoutGatewaySettingsDecodes() throws {
        let id = UUID()
        let stored = Data(
            """
            [{"id":"\(id.uuidString)","name":"Офис","address":"win","username":"alice",
              "remembersPassword":false,"keyboard":"pc"}]
            """.utf8)
        defaults.set(stored, forKey: ProfileStore.defaultsKey)
        let profile = try XCTUnwrap(ProfileStore(defaults: defaults, passwords: MemoryPasswordStore()).profile(id))
        XCTAssertEqual(profile.name, "Офис")
        XCTAssertFalse(profile.remembersPassword)
        XCTAssertEqual(profile.keyboard, .pc)
        XCTAssertEqual(profile.gatewayAddress, "")
        XCTAssertNil(profile.gateway)
        XCTAssertTrue(profile.gatewayUsesServerCredentials)
        XCTAssertTrue(profile.hasValidGateway)
        XCTAssertEqual(profile.displayMode, .window, "a profile saved before the modes follows the window, as then")
        XCTAssertEqual(profile.fixedSize, .standard)
        XCTAssertTrue(profile.sharpOnRetina, "a profile saved before is sharp on Retina, as new ones are")
        XCTAssertFalse(profile.isFavorite)
        XCTAssertNil(profile.lastConnected)
        XCTAssertEqual(profile.audio, .local, "a profile saved before plays its sound on this Mac")
    }

    /// The display mode and the fixed size are saved with the profile
    func testDisplaySettingsAreKept() throws {
        let store = ProfileStore(defaults: defaults, passwords: MemoryPasswordStore())
        let profile = ConnectionProfile(
            address: "win", displayMode: .fixed, fixedSize: DesktopSize(width: 1600, height: 900))
        store.add(profile)
        let read = try XCTUnwrap(ProfileStore(defaults: defaults, passwords: MemoryPasswordStore()).profile(profile.id))
        XCTAssertEqual(read.displayMode, .fixed)
        XCTAssertEqual(read.fixedSize, DesktopSize(width: 1600, height: 900))
    }

    /// A size goes within the limits of the protocol, its width even
    func testDesktopSizeStaysWithinTheProtocol() {
        XCTAssertEqual(DesktopSize(width: 199, height: 9000).clamped, DesktopSize(width: 200, height: 8192))
        XCTAssertEqual(DesktopSize(width: 1367, height: 767).clamped, DesktopSize(width: 1366, height: 767))
        XCTAssertEqual(DesktopSize(width: 8193, height: 100).clamped, DesktopSize(width: 8192, height: 200))
        for preset in DesktopSize.presets {
            XCTAssertEqual(preset.clamped, preset, "every preset is a size the server takes")
        }
        XCTAssertTrue(DesktopSize.presets.contains(.standard))
    }

    func testUnreadableProfilesLeaveTheListEmpty() {
        defaults.set(Data("not json".utf8), forKey: ProfileStore.defaultsKey)
        XCTAssertEqual(ProfileStore(defaults: defaults, passwords: MemoryPasswordStore()).profiles, [])
    }

    /// The name shows, else the address; the keyboard preset keeps the shortcuts and the ISO switch of the app
    func testTitleAndKeyboardPreset() {
        XCTAssertEqual(ConnectionProfile(name: "  ", address: " win ").title, "win")
        XCTAssertEqual(ConnectionProfile(name: "Офис", address: "win").title, "Офис")

        var settings = KeyboardSettings.standard
        settings.isoKeyboard = true
        settings.modifiers[.leftOption] = .windows
        XCTAssertEqual(ProfileKeyboard.settings.applied(to: settings), settings)
        let pc = ProfileKeyboard.pc.applied(to: settings)
        XCTAssertEqual(pc.modifiers, KeyboardSettings.pcModifiers)
        XCTAssertTrue(pc.isoKeyboard)
        XCTAssertEqual(pc.macShortcuts, settings.macShortcuts)
        XCTAssertEqual(ProfileKeyboard.mac.applied(to: settings).modifiers, KeyboardSettings.macModifiers)
    }
}

/// The list, the selection and the password typed in the editor
@MainActor
final class ConnectionsModelTests: XCTestCase {
    private var suiteName = ""
    private var passwords: MemoryPasswordStore!
    private var model: ConnectionsModel!
    private var snapshotsRoot: URL!

    override func setUp() async throws {
        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        passwords = MemoryPasswordStore()
        snapshotsRoot = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        let store = ProfileStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)), passwords: passwords)
        model = ConnectionsModel(store: store, snapshots: SessionSnapshots(root: snapshotsRoot))
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: snapshotsRoot)
    }

    /// The tiles of a section: favourites only there, the search over title, address and user, in the chosen order
    func testVisibleProfiles() {
        let now = Date()
        let profiles = [
            ConnectionProfile(name: "Бухгалтерия", address: "acc", username: "CORP\\anna", lastConnected: now),
            ConnectionProfile(name: "аптека", address: "pharm", isFavorite: true),
            ConnectionProfile(
                name: "Сервер", address: "srv", isFavorite: true, lastConnected: now.addingTimeInterval(-60)),
        ]
        func titles(_ section: ConnectionsSection, _ search: String, _ sort: ConnectionsSort) -> [String] {
            ConnectionsModel.visible(profiles, section: section, search: search, sort: sort).map(\.title)
        }
        XCTAssertEqual(titles(.all, "", .name), ["аптека", "Бухгалтерия", "Сервер"], "by name, whatever the case")
        XCTAssertEqual(titles(.all, "", .lastConnected), ["Бухгалтерия", "Сервер", "аптека"])
        XCTAssertEqual(titles(.favorites, "", .name), ["аптека", "Сервер"])
        XCTAssertEqual(titles(.all, "ANNA", .name), ["Бухгалтерия"], "the user matches too")
        XCTAssertEqual(titles(.all, " srv ", .name), ["Сервер"], "the address matches, spaces aside")
        XCTAssertEqual(titles(.favorites, "acc", .name), [])
    }

    /// A dragged tile takes the place of the one under it; the order the tiles showed becomes the manual one first,
    /// and the order and the layout stay for the next launch
    func testDragReorders() throws {
        for name in ["В", "Б", "А"] {
            model.addProfile()
            model.update { $0.name = name }
        }
        XCTAssertEqual(model.sort, .name)
        XCTAssertEqual(model.visibleProfiles.map(\.title), ["А", "Б", "В"])
        let a = model.visibleProfiles[0].id
        let c = model.visibleProfiles[2].id
        model.move(c, to: a)
        XCTAssertEqual(model.sort, .manual)
        XCTAssertEqual(model.visibleProfiles.map(\.title), ["В", "А", "Б"], "the shown order was kept, then В moved")
        model.move(c, to: model.visibleProfiles[2].id)
        XCTAssertEqual(model.visibleProfiles.map(\.title), ["А", "Б", "В"])
        model.layout = .list

        let again = ConnectionsModel(store: ProfileStore(defaults: model.store.defaults, passwords: passwords))
        XCTAssertEqual(again.sort, .manual)
        XCTAssertEqual(again.layout, .list)
        XCTAssertEqual(again.visibleProfiles.map(\.title), ["А", "Б", "В"])
    }

    /// A row moved in a list lands in place of the row at the drop above it, of the one before the drop below it
    func testListMoveTarget() {
        let profiles = ["a", "b", "c", "d"].map { ConnectionProfile(name: $0, address: $0) }
        XCTAssertEqual(ConnectionsModel.target(moving: 3, to: 0, in: profiles), profiles[0].id)
        XCTAssertEqual(ConnectionsModel.target(moving: 0, to: 4, in: profiles), profiles[3].id)
        XCTAssertEqual(ConnectionsModel.target(moving: 0, to: 2, in: profiles), profiles[1].id)
        XCTAssertNil(ConnectionsModel.target(moving: 1, to: 1, in: profiles))
        XCTAssertNil(ConnectionsModel.target(moving: 1, to: 2, in: profiles), "a drop right below a row leaves it")
    }

    /// A tile goes to the favourites and back; a new connection opens in the edit sheet
    func testFavoriteAndAddAndEdit() throws {
        model.addAndEdit()
        let id = try XCTUnwrap(model.selection)
        XCTAssertEqual(model.editing, id)
        XCTAssertFalse(try XCTUnwrap(model.store.profile(id)).isFavorite)
        model.toggleFavorite(id)
        XCTAssertTrue(try XCTUnwrap(model.store.profile(id)).isFavorite)
        model.section = .favorites
        XCTAssertEqual(model.visibleProfiles.map(\.id), [id])
        model.toggleFavorite(id)
        XCTAssertEqual(model.visibleProfiles, [])
    }

    /// A connection deleted from its tile takes its picture along and closes its sheet
    func testDeleteTakesThePicture() throws {
        model.addProfile()
        let id = try XCTUnwrap(model.selection)
        model.addProfile()
        let other = try XCTUnwrap(model.selection)
        model.edit(id)
        XCTAssertTrue(model.snapshots.save(try TestSurface.make(), for: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.snapshots.url(for: id).path))
        model.delete(id)
        XCTAssertNil(model.store.profile(id))
        XCTAssertNil(model.editing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.snapshots.url(for: id).path))
        XCTAssertEqual(model.selection, other)
    }

    /// The last desktop becomes a picture a tile shows: scaled down to the width, its proportions kept
    func testSnapshotOfTheDesktop() throws {
        model.addProfile()
        let id = try XCTUnwrap(model.selection)
        let revision = model.snapshotRevision
        model.keepSnapshot(try TestSurface.make(width: 1280, height: 800), for: id)
        XCTAssertEqual(model.snapshotRevision, revision + 1)
        let image = try XCTUnwrap(NSImage(contentsOf: model.snapshots.url(for: id)))
        let rep = try XCTUnwrap(image.representations.first)
        XCTAssertEqual(rep.pixelsWide, SessionSnapshots.width)
        XCTAssertEqual(rep.pixelsHigh, SessionSnapshots.width * 800 / 1280)
        XCTAssertNotNil(model.snapshots.image(for: id))
    }

    func testAddSelectsTheNewProfile() {
        XCTAssertNil(model.selection)
        model.addProfile()
        let profile = model.selectedProfile
        XCTAssertEqual(profile?.name, Localization.text(.connectionsNewName))
        XCTAssertEqual(model.store.profiles.count, 1)
        XCTAssertTrue(profile?.remembersPassword ?? false)
    }

    /// Deleting keeps a selection: the next profile, or the last one when the deleted was last
    func testDeleteSelectsANeighbour() {
        for _ in 0..<3 {
            model.addProfile()
        }
        let ids = model.store.profiles.map(\.id)
        model.selection = ids[1]
        model.deleteSelected()
        XCTAssertEqual(model.selection, ids[2])
        model.deleteSelected()
        XCTAssertEqual(model.selection, ids[0])
        model.deleteSelected()
        XCTAssertNil(model.selection)
    }

    /// A readable address, a readable gateway or none, and no session running
    func testCanConnect() {
        model.addProfile()
        XCTAssertFalse(model.canConnect)
        model.update { $0.address = "win.corp:3390" }
        XCTAssertTrue(model.canConnect)
        model.update { $0.gatewayAddress = "two words" }
        XCTAssertFalse(model.canConnect, "an unreadable gateway must not quietly connect directly")
        model.update { $0.gatewayAddress = "gw.corp:8443" }
        XCTAssertTrue(model.canConnect)
        model.isBusy = true
        XCTAssertFalse(model.canConnect)
        model.isBusy = false
        model.update { $0.address = "two words" }
        XCTAssertFalse(model.canConnect)
    }

    /// The typed password belongs to the profile it was typed for, and the saved one is known without reading it
    func testSelectionClearsTheTypedPassword() throws {
        model.addProfile()
        let first = try XCTUnwrap(model.selection)
        model.addProfile()
        XCTAssertEqual(passwords.setPassword("secret", for: first, kind: .server, label: "x"), errSecSuccess)
        model.password = "typed"
        model.selection = first
        XCTAssertEqual(model.password, "")
        XCTAssertTrue(model.hasSavedPassword)
    }

    /// Turning remembering off forgets the saved password at once
    func testRememberOffForgetsThePassword() throws {
        model.addProfile()
        let id = try XCTUnwrap(model.selection)
        XCTAssertEqual(passwords.setPassword("secret", for: id, kind: .server, label: "x"), errSecSuccess)
        model.refreshSavedPassword()
        XCTAssertTrue(model.hasSavedPassword)

        model.setRemembersPassword(false)
        XCTAssertEqual(model.selectedProfile?.remembersPassword, false)
        XCTAssertNil(passwords.password(for: id, kind: .server))
        XCTAssertFalse(model.hasSavedPassword)
    }

    func testConnectAsksTheWindowOnlyWhenItCan() throws {
        var asked: [UUID] = []
        model.onConnect = { asked.append($0) }
        model.addProfile()
        model.connect()
        XCTAssertEqual(asked, [])
        model.update { $0.address = "win" }
        model.connect()
        XCTAssertEqual(asked, [try XCTUnwrap(model.selection)])
    }

    /// The list lays out with profiles and without them
    func testViewLaysOut() {
        let view = NSHostingView(rootView: ConnectionsView(model: model))
        view.frame = NSRect(origin: .zero, size: MainWindow.defaultSize)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.width, ConnectionsView.sidebarWidth)
        model.addProfile()
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.width, ConnectionsView.sidebarWidth)
    }
}

/// Which password a try uses, and which one reaches the Keychain
final class LoginAttemptTests: XCTestCase {
    private let profile = ConnectionProfile(address: "win", username: "CORP\\alice")

    func testTypedPasswordWinsOverTheSavedOne() {
        let typed = LoginAttempt.first(for: profile, typed: "typed", saved: "saved", savedGateway: nil)
        XCTAssertEqual(typed.password, "typed")
        XCTAssertTrue(typed.typedByUser)
        XCTAssertEqual(typed.username, "CORP\\alice")
        XCTAssertEqual(typed.passwordToSave, "typed")

        let saved = LoginAttempt.first(for: profile, typed: "", saved: "saved", savedGateway: nil)
        XCTAssertEqual(saved.password, "saved")
        XCTAssertFalse(saved.typedByUser)
        XCTAssertNil(saved.passwordToSave, "a saved password is not saved again")

        let none = LoginAttempt.first(for: profile, typed: "", saved: nil, savedGateway: nil)
        XCTAssertNil(none.password)
        XCTAssertNil(none.passwordToSave)
    }

    /// The gateway's own password is saved apart from the computer's, and only when the user typed it
    func testGatewayPassword() {
        var attempt = LoginAttempt.first(for: profile, typed: "typed", saved: nil, savedGateway: "gate-saved")
        XCTAssertEqual(attempt.gatewayPassword, "gate-saved")
        XCTAssertNil(attempt.gatewayPasswordToSave, "a saved gateway password is not saved again")
        attempt.answeredGateway(username: "GW\\bob", password: "gate-new", remember: true)
        XCTAssertEqual(attempt.gatewayUsername, "GW\\bob")
        XCTAssertEqual(attempt.gatewayPasswordToSave, "gate-new")
        XCTAssertEqual(attempt.passwordToSave, "typed")
    }

    /// An answer to a question is the user's own password, saved only when the box stays ticked
    func testAnsweredPassword() {
        var attempt = LoginAttempt.first(for: profile, typed: "", saved: "old", savedGateway: nil)
        attempt.answered(username: "bob@corp", password: "new", remember: true)
        XCTAssertEqual(attempt.username, "bob@corp")
        XCTAssertEqual(attempt.passwordToSave, "new")

        attempt.answered(username: "bob@corp", password: "new", remember: false)
        XCTAssertNil(attempt.passwordToSave)
        attempt.answered(username: "bob@corp", password: "", remember: true)
        XCTAssertNil(attempt.passwordToSave, "an empty answer has nothing to save")
    }
}

/// The login keychain itself, under a service of the test's own, emptied afterwards
@MainActor
final class KeychainPasswordStoreTests: XCTestCase {
    private var store: KeychainPasswordStore!
    private let id = UUID()

    override func setUp() async throws {
        store = KeychainPasswordStore(service: "tech.vibebrains.viberdp.tests.\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        for kind in PasswordKind.allCases {
            store.deletePassword(for: id, kind: kind)
        }
    }

    func testSaveReadReplaceAndDelete() {
        XCTAssertFalse(store.hasPassword(for: id, kind: .server))
        XCTAssertNil(store.password(for: id, kind: .server))

        XCTAssertEqual(
            store.setPassword("первый пароль", for: id, kind: .server, label: "VibeRDP: тест"), errSecSuccess)
        XCTAssertTrue(store.hasPassword(for: id, kind: .server))
        XCTAssertEqual(store.password(for: id, kind: .server), "первый пароль")

        XCTAssertEqual(store.setPassword("второй", for: id, kind: .server, label: "VibeRDP: тест"), errSecSuccess)
        XCTAssertEqual(store.password(for: id, kind: .server), "второй")
        XCTAssertNil(store.password(for: UUID(), kind: .server))

        store.deletePassword(for: id, kind: .server)
        XCTAssertFalse(store.hasPassword(for: id, kind: .server))
    }

    /// The gateway's password is a separate item of the same profile
    func testGatewayPasswordIsSeparate() {
        XCTAssertEqual(store.setPassword("computer", for: id, kind: .server, label: "VibeRDP: тест"), errSecSuccess)
        XCTAssertEqual(
            store.setPassword("gateway", for: id, kind: .gateway, label: "VibeRDP, шлюз: тест"), errSecSuccess)
        XCTAssertEqual(store.password(for: id, kind: .server), "computer")
        XCTAssertEqual(store.password(for: id, kind: .gateway), "gateway")
        store.deletePassword(for: id, kind: .gateway)
        XCTAssertEqual(store.password(for: id, kind: .server), "computer")
        XCTAssertFalse(store.hasPassword(for: id, kind: .gateway))
    }
}

/// The question for a name and a password
@MainActor
final class CredentialsPromptTests: XCTestCase {
    func testPromptAsksAndReadsTheAnswer() throws {
        let prompt = CredentialsPrompt(
            target: .server, host: "win", username: "CORP\\alice", remember: true, retry: false)
        XCTAssertEqual(prompt.alert.messageText, Localization.text(.credentialsTitleServer, ["host": "win"]))
        XCTAssertEqual(prompt.alert.informativeText, Localization.text(.credentialsMessageAsk))
        XCTAssertEqual(
            prompt.alert.buttons.map(\.title),
            [
                Localization.text(.credentialsActionSignIn), Localization.text(.credentialsActionCancel),
            ])
        XCTAssertEqual(prompt.userField.stringValue, "CORP\\alice")
        XCTAssertIdentical(prompt.alert.window.initialFirstResponder, prompt.passwordField)
        XCTAssertEqual(prompt.alert.suppressionButton?.state, .on)

        prompt.passwordField.stringValue = "secret"
        prompt.alert.suppressionButton?.state = .off
        let answer = try XCTUnwrap(prompt.answer(for: .alertFirstButtonReturn))
        XCTAssertEqual(answer.username, "CORP\\alice")
        XCTAssertEqual(answer.password, "secret")
        XCTAssertFalse(answer.remember)
        XCTAssertNil(prompt.answer(for: .alertSecondButtonReturn))
        XCTAssertNil(prompt.answer(for: .abort))
    }

    /// After a wrong password the question says so; without a name typing starts in the name
    func testRetryAndGateway() {
        let retry = CredentialsPrompt(target: .server, host: "win", username: "", remember: false, retry: true)
        XCTAssertEqual(retry.alert.informativeText, Localization.text(.credentialsMessageRetry))
        XCTAssertIdentical(retry.alert.window.initialFirstResponder, retry.userField)
        XCTAssertEqual(retry.alert.suppressionButton?.state, .off)

        let gateway = CredentialsPrompt(target: .gateway, host: "win", username: "", remember: true, retry: false)
        XCTAssertEqual(gateway.alert.messageText, Localization.text(.credentialsTitleGateway, ["host": "win"]))
    }
}
