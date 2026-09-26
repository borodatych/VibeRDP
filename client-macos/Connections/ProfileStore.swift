import Foundation
import Observation

/// The saved connections, kept in the app defaults in the order they were added or the user moved them to
/// A profile that goes takes its saved passwords with it
@MainActor
@Observable
final class ProfileStore {
    static let defaultsKey = "connections"

    /// Also keeps how the window shows the connections: the view belongs with the list it shows
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let passwords: PasswordStore

    private(set) var profiles: [ConnectionProfile] {
        didSet {
            if let data = try? JSONEncoder().encode(profiles) {
                defaults.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    /// Stored profiles that do not decode, written by another version for one, leave the list empty
    /// rather than stopping the app; the defaults keep them until the first change
    init(defaults: UserDefaults = .standard, passwords: PasswordStore) {
        self.defaults = defaults
        self.passwords = passwords
        profiles =
            defaults.data(forKey: Self.defaultsKey).flatMap {
                try? JSONDecoder().decode([ConnectionProfile].self, from: $0)
            } ?? []
    }

    func profile(_ id: UUID) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    /// The profile takes the place of the target, and those between shift by one toward where it was
    func move(_ id: UUID, to target: UUID) {
        guard id != target, let from = profiles.firstIndex(where: { $0.id == id }),
            let to = profiles.firstIndex(where: { $0.id == target })
        else { return }
        var reordered = profiles
        reordered.insert(reordered.remove(at: from), at: to)
        profiles = reordered
    }

    /// The profiles in the order of these ids; a profile the ids miss keeps its place at the end
    func reorder(_ ids: [UUID]) {
        let named = ids.compactMap(profile)
        profiles = named + profiles.filter { !ids.contains($0.id) }
    }

    func add(_ profile: ConnectionProfile) {
        profiles.append(profile)
    }

    /// Replaces the profile of the same id; an unknown id changes nothing
    func update(_ profile: ConnectionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }), profiles[index] != profile else {
            return
        }
        profiles[index] = profile
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        for kind in PasswordKind.allCases {
            passwords.deletePassword(for: id, kind: kind)
        }
    }
}
