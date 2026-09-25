import Foundation
import Observation

/// The saved connections, kept in the app defaults in the order they were added
/// A profile that goes takes its saved password with it
@MainActor
@Observable
final class ProfileStore {
    static let defaultsKey = "connections"

    @ObservationIgnored private let defaults: UserDefaults
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
        passwords.deletePassword(for: id)
    }
}
