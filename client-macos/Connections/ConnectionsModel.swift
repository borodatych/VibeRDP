import Foundation
import IOSurface
import Observation

/// The parts of the sidebar
enum ConnectionsSection: String, CaseIterable, Identifiable, Sendable {
    case favorites, all

    var id: Self { self }
}

/// The order of the tiles
enum ConnectionsSort: String, CaseIterable, Identifiable, Sendable {
    /// By title, as the Finder sorts names
    case name
    /// The last connected first; those never connected follow by title
    case lastConnected

    var id: Self { self }
}

/// The connections as tiles or as rows
enum ConnectionsLayout: String, CaseIterable, Identifiable, Sendable {
    case grid, list

    var id: Self { self }
}

/// The state of the connection list: the saved profiles, the one selected, and how the last connection went
/// Every edit goes to the store at once; the window controller runs the sessions the model asks for
@MainActor
@Observable
final class ConnectionsModel {
    let store: ProfileStore
    /// The last picture of each connection, for its tile
    @ObservationIgnored let snapshots: SessionSnapshots

    var section: ConnectionsSection = .all
    var sort: ConnectionsSort = .name
    var layout: ConnectionsLayout = .grid
    var searchText = ""
    /// The profile the edit sheet shows, nil while it is closed
    var editing: UUID?
    /// The profile whose session runs, while one does
    var activeProfile: UUID?
    /// Grows with every new picture, so the tiles read it again
    private(set) var snapshotRevision = 0

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

    init(store: ProfileStore, snapshots: SessionSnapshots = SessionSnapshots()) {
        self.store = store
        self.snapshots = snapshots
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

    /// A new connection opens in the edit sheet, where its address is typed
    func addAndEdit() {
        addProfile()
        editing = selection
    }

    /// The profiles the content shows: of the section, matching the search, in the chosen order
    var visibleProfiles: [ConnectionProfile] {
        Self.visible(store.profiles, section: section, search: searchText, sort: sort)
    }

    /// The search matches the title, the address and the user, whatever the case
    static func visible(
        _ profiles: [ConnectionProfile], section: ConnectionsSection, search: String, sort: ConnectionsSort
    ) -> [ConnectionProfile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = profiles.filter { profile in
            (section == .all || profile.isFavorite)
                && (query.isEmpty
                    || [profile.title, profile.address, profile.username].contains {
                        $0.localizedCaseInsensitiveContains(query)
                    })
        }
        let byTitle: (ConnectionProfile, ConnectionProfile) -> Bool = {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        switch sort {
        case .name:
            return shown.sorted(by: byTitle)
        case .lastConnected:
            return shown.sorted { first, second in
                switch (first.lastConnected, second.lastConnected) {
                case let (a?, b?): a == b ? byTitle(first, second) : a > b
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): byTitle(first, second)
                }
            }
        }
    }

    func edit(_ id: UUID) {
        selection = id
        editing = id
    }

    func toggleFavorite(_ id: UUID) {
        guard var profile = store.profile(id) else { return }
        profile.isFavorite.toggle()
        store.update(profile)
    }

    /// The last desktop of a session becomes the picture of its tile
    func keepSnapshot(_ surface: IOSurfaceRef, for id: UUID) {
        if snapshots.save(surface, for: id) {
            snapshotRevision += 1
        }
    }

    /// The profile goes with its passwords and its picture; the one next to it takes the selection
    func delete(_ id: UUID) {
        selection = id
        deleteSelected()
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
        snapshots.remove(for: id)
        if editing == id {
            editing = nil
        }
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

    /// A double click on a tile: the profile is selected and connects when it can
    func connect(_ id: UUID) {
        selection = id
        connect()
    }

    func disconnect() {
        onDisconnect?()
    }

    func refreshSavedPassword() {
        hasSavedPassword = selection.map { store.passwords.hasPassword(for: $0, kind: .server) } ?? false
        hasSavedGatewayPassword = selection.map { store.passwords.hasPassword(for: $0, kind: .gateway) } ?? false
    }
}
