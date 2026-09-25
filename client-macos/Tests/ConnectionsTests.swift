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

    /// A profile that goes takes its saved password with it
    func testDeleteForgetsThePassword() {
        let passwords = MemoryPasswordStore()
        let store = ProfileStore(defaults: defaults, passwords: passwords)
        let profile = ConnectionProfile(address: "win")
        store.add(profile)
        XCTAssertEqual(passwords.setPassword("secret", for: profile.id, label: "x"), errSecSuccess)
        store.delete(profile.id)
        XCTAssertEqual(store.profiles, [])
        XCTAssertNil(passwords.password(for: profile.id))
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

    override func setUp() async throws {
        suiteName = "tech.vibebrains.viberdp.tests.\(UUID().uuidString)"
        passwords = MemoryPasswordStore()
        let store = ProfileStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)), passwords: passwords)
        model = ConnectionsModel(store: store)
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
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

    /// A readable address and no session running
    func testCanConnect() {
        model.addProfile()
        XCTAssertFalse(model.canConnect)
        model.update { $0.address = "win.corp:3390" }
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
        XCTAssertEqual(passwords.setPassword("secret", for: first, label: "x"), errSecSuccess)
        model.password = "typed"
        model.selection = first
        XCTAssertEqual(model.password, "")
        XCTAssertTrue(model.hasSavedPassword)
    }

    /// Turning remembering off forgets the saved password at once
    func testRememberOffForgetsThePassword() throws {
        model.addProfile()
        let id = try XCTUnwrap(model.selection)
        XCTAssertEqual(passwords.setPassword("secret", for: id, label: "x"), errSecSuccess)
        model.refreshSavedPassword()
        XCTAssertTrue(model.hasSavedPassword)

        model.setRemembersPassword(false)
        XCTAssertEqual(model.selectedProfile?.remembersPassword, false)
        XCTAssertNil(passwords.password(for: id))
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
        let typed = LoginAttempt.first(for: profile, typed: "typed", saved: "saved")
        XCTAssertEqual(typed.password, "typed")
        XCTAssertTrue(typed.typedByUser)
        XCTAssertEqual(typed.username, "CORP\\alice")
        XCTAssertEqual(typed.passwordToSave, "typed")

        let saved = LoginAttempt.first(for: profile, typed: "", saved: "saved")
        XCTAssertEqual(saved.password, "saved")
        XCTAssertFalse(saved.typedByUser)
        XCTAssertNil(saved.passwordToSave, "a saved password is not saved again")

        let none = LoginAttempt.first(for: profile, typed: "", saved: nil)
        XCTAssertNil(none.password)
        XCTAssertNil(none.passwordToSave)
    }

    /// An answer to a question is the user's own password, saved only when the box stays ticked
    func testAnsweredPassword() {
        var attempt = LoginAttempt.first(for: profile, typed: "", saved: "old")
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
        store.deletePassword(for: id)
    }

    func testSaveReadReplaceAndDelete() {
        XCTAssertFalse(store.hasPassword(for: id))
        XCTAssertNil(store.password(for: id))

        XCTAssertEqual(store.setPassword("первый пароль", for: id, label: "VibeRDP: тест"), errSecSuccess)
        XCTAssertTrue(store.hasPassword(for: id))
        XCTAssertEqual(store.password(for: id), "первый пароль")

        XCTAssertEqual(store.setPassword("второй", for: id, label: "VibeRDP: тест"), errSecSuccess)
        XCTAssertEqual(store.password(for: id), "второй")
        XCTAssertNil(store.password(for: UUID()))

        store.deletePassword(for: id)
        XCTAssertFalse(store.hasPassword(for: id))
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
