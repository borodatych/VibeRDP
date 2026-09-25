import Foundation
import Observation

/// The state of the connection list: the saved profiles, the one selected, and how the last connection went
/// Every edit goes to the store at once; the window controller runs the sessions the model asks for
@MainActor
@Observable
final class ConnectionsModel {
    let store: ProfileStore

    var selection: UUID? {
        didSet {
            guard selection != oldValue else { return }
            password = ""
            refreshSavedPassword()
        }
    }

    /// Typed in the editor for the selected profile: used for the next connection, never kept in the store
    var password = ""
    private(set) var hasSavedPassword = false
    private(set) var hasSavedGatewayPassword = false
    /// How the last connection went, in the user's words
    var status = ""
    /// A session exists, from the start of connecting until Disconnected: the list and the editor wait for it
    var isBusy = false

    /// Windows App is installed: its connections can be brought over
    var windowsAppInstalled = false

    @ObservationIgnored var onConnect: ((UUID) -> Void)?
    @ObservationIgnored var onDisconnect: (() -> Void)?
    @ObservationIgnored var onImportWindowsApp: (() -> Void)?

    init(store: ProfileStore) {
        self.store = store
        selection = store.profiles.first?.id
        refreshSavedPassword()
    }

    var selectedProfile: ConnectionProfile? {
        selection.flatMap(store.profile)
    }

    /// The selected profile has an address and a gateway field the client can read, and no session is running
    var canConnect: Bool {
        guard !isBusy, let profile = selectedProfile else { return false }
        return ServerAddress(profile.address) != nil && profile.hasValidGateway
    }

    func update(_ change: (inout ConnectionProfile) -> Void) {
        guard var profile = selectedProfile else { return }
        change(&profile)
        store.update(profile)
    }

    func addProfile() {
        let profile = ConnectionProfile(name: Localization.text(.connectionsNewName))
        store.add(profile)
        selection = profile.id
    }

    /// A profile from a file: the one already in the list for the same computer and user, or a new one
    /// Returns whether the list grew, and selects the profile either way
    @discardableResult
    func importProfile(_ profile: ConnectionProfile) -> Bool {
        let existing = store.profiles.first {
            $0.address.caseInsensitiveCompare(profile.address) == .orderedSame
                && $0.username.caseInsensitiveCompare(profile.username) == .orderedSame
        }
        if let existing {
            selection = existing.id
            return false
        }
        store.add(profile)
        selection = profile.id
        return true
    }

    /// Profiles of another client, one by one as importProfile takes them: how many joined and how many were there
    func importProfiles(_ profiles: [ConnectionProfile]) -> (added: Int, existing: Int) {
        let added = profiles.filter { importProfile($0) }.count
        return (added, profiles.count - added)
    }

    func importWindowsApp() {
        onImportWindowsApp?()
    }

    /// The profile next to the deleted one takes the selection, so the list keeps one
    func deleteSelected() {
        guard let id = selection, let index = store.profiles.firstIndex(where: { $0.id == id }) else { return }
        store.delete(id)
        let remaining = store.profiles
        selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }

    /// Turning remembering off forgets the saved password at once
    func setRemembersPassword(_ remembers: Bool) {
        update { $0.remembersPassword = remembers }
        if !remembers {
            forgetPassword()
        }
    }

    /// Forgets the saved passwords, both of the computer and of the gateway
    func forgetPassword() {
        guard let id = selection else { return }
        for kind in PasswordKind.allCases {
            store.passwords.deletePassword(for: id, kind: kind)
        }
        refreshSavedPassword()
    }

    func connect() {
        guard canConnect, let id = selection else { return }
        onConnect?(id)
    }

    func disconnect() {
        onDisconnect?()
    }

    func refreshSavedPassword() {
        hasSavedPassword = selection.map { store.passwords.hasPassword(for: $0, kind: .server) } ?? false
        hasSavedGatewayPassword = selection.map { store.passwords.hasPassword(for: $0, kind: .gateway) } ?? false
    }
}
